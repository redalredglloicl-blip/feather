//
//  SigningHandler.swift
//  Zenith
//
//  Created by samara on 17.04.2025.
//

import Foundation
import ZsignC
import UIKit
import OSLog

final class SigningHandler: NSObject {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private var _movedAppPath: URL?
	// using uuid string is the best way to find the
	// app we want to sign, it does not matter what
	// type of app it is
	private var _app: AppInfoPresentable
	private var _options: Options
	private let _uniqueWorkDir: URL
	// the options struct is not gonna decode these so
	// we're just going to do this. If appicon is not
	// specified, we're not going to modify the app
	// icon. If the cert pair is not there, fallback
	// to adhoc signing (if the option is on, otherwise
	// throw an error
	var appIcon: UIImage?
	var appCertificate: CertificatePair?
	
	init(app: AppInfoPresentable, options: Options = OptionsManager.shared.options) {
		self._app = app
		self._options = options
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("ZenithSigning_\(_uuid)", isDirectory: true)
		super.init()
	}
	
	func copy() async throws {
		guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
			throw SigningFileHandlerError.appNotFound
		}

		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
		
		let movedAppURL = _uniqueWorkDir.appendingPathComponent(appUrl.lastPathComponent)
		
		try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		_movedAppPath = movedAppURL
		Logger.misc.info("[\(self._uuid)] Moved Payload to: \(movedAppURL.path)")
		
		// Zenith v2.12 item 5: keep the untouched original before
		// modify() changes anything (dylib injection, custom name,
		// file removal, ...). Gated on the signing-screen toggle
		// (BackupOriginalRowView, "التعديل" item 7); a failure here
		// never blocks signing.
		_ = await BackupManager.shared.backupAppDirectory(
			movedAppURL,
			appName: _app.name,
			appVersion: _app.version
		)
	}
	
	func modify() async throws {
		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}
		
		guard
			let infoDictionary = NSDictionary(
				contentsOf: movedAppPath.appendingPathComponent("Info.plist")
			)?.mutableCopy() as? NSMutableDictionary
		else {
			throw SigningFileHandlerError.infoPlistNotFound
		}
		
		// Zenith v2.12: a custom display name remembered per app in
		// displayNames (key = the app's real name) applies on every
		// signing path, even when the caller left appName unset —
		// the batch queue signs with the shared options and never
		// runs the signing sheet's prefill. An explicitly set
		// appName always wins.
		if _options.appName == nil,
		   let realName = _app.name,
		   let rememberedName = _options.displayNames[realName]
		{
			_options.appName = rememberedName
		}
		
		if
			let identifier = _options.appIdentifier,
			let oldIdentifier = infoDictionary["CFBundleIdentifier"] as? String
		{
			try await _modifyPluginIdentifiers(old: oldIdentifier, new: identifier, for: movedAppPath)
		}
		
		try await _modifyDict(using: infoDictionary, with: _options, to: movedAppPath)
		
		if let icon = appIcon {
			try await _modifyDict(using: infoDictionary, for: icon, to: movedAppPath)
		}
		
		if let name = _options.appName {
			try await _modifyLocalesForName(name, for: movedAppPath)
		}
		
		if !_options.removeFiles.isEmpty {
			try await _removeFiles(for: movedAppPath, from: _options.removeFiles)
		}
		
		try await _removePresetFiles(for: movedAppPath)
		try await _removeWatchIfNeeded(for: movedAppPath)
		
		if _options.experiment_supportLiquidGlass {
			try await _locateMachosAndChangeToSDK26(for: movedAppPath)
		}
		
		// Zenith v2.20: refresh staged copies of the bundled
		// overlay dylibs first (see
		// TweakHandler.refreshStagedBundledOverlays) — a staged
		// copy made by an older Zenith would otherwise be
		// injected forever. Runs on every signing, before any
		// injection, single sign and batch queue alike.
		TweakHandler.refreshStagedBundledOverlays(in: _options)
		
		if _options.experiment_replaceSubstrateWithEllekit {
			try await _inject(for: movedAppPath, with: _options)
		} else {
			if !_options.injectionFiles.isEmpty {
				try await _inject(for: movedAppPath, with: _options)
			}
		}

		// Zenith v2.12, item 4: apply the user's staged local-file
		// edits (money, points, ...) to the copied .app before
		// re-signing, so the edited files are covered by the fresh
		// signature. Throws on the first bad edit — a half-applied
		// set is never silently signed.
		if !_options.modFileEdits.isEmpty {
			try await ModFileEditor.apply(edits: _options.modFileEdits, to: movedAppPath)
		}

		// Zenith v2.12, item 8 (#23): strip the ad SDK frameworks
		// the user chose — only ones the detector verified as
		// unlinked, so the app still launches. Throws on the first
		// framework that cannot be removed safely, so a
		// half-stripped app is never signed.
		if !_options.removeAdsSDKs.isEmpty {
			try AdSDKRemover.apply(frameworks: _options.removeAdsSDKs, to: movedAppPath)
		}
		// Zenith v2.12, item 23 (#100): strip the files the user
		// chose for the Lite version — only ones the detector
		// proved safe to remove; re-verified at signing time.
		if !_options.liteStripPaths.isEmpty {
			try LiteStripRemover.apply(paths: _options.liteStripPaths, to: movedAppPath)
		}
		// Zenith v2.12, item 9 (#24): enable the hidden
		// developer-menu flags the user chose.
		if !_options.devMenuChanges.isEmpty {
			try DevMenuApplier.apply(changes: _options.devMenuChanges, to: movedAppPath)
		}
		// Zenith v2.12, item 17 (#45): replace bundled fonts with
		// the user-supplied font files (same file names, so
		// UIAppFonts keeps working).
		if !_options.fontReplacements.isEmpty {
			try AppFontApplier.apply(replacements: _options.fontReplacements, to: movedAppPath)
		}
		// Zenith v2.12, item 18 (#46): shorten local animation
		// durations (original × 0.5).
		if !_options.animationDurationChanges.isEmpty {
			try AnimationSpeedApplier.apply(changes: _options.animationDurationChanges, to: movedAppPath)
		}

		// Zenith v2.12, items 13-16 (#40-#43): apply the staged
		// app-modding patches to the copied .app before re-signing,
		// so they are covered by the fresh signature. Each applier
		// re-verifies its staged entries against the copied bundle
		// and throws on the first entry that cannot be applied —
		// a half-patched set is never silently signed.
		// #40 remove watermark: local config changes first, then
		// the proven-unlinked watermark frameworks.
		if !_options.removeWatermarkChanges.isEmpty {
			try await AppConfigApplier.apply(changes: _options.removeWatermarkChanges, to: movedAppPath)
		}
		if !_options.removeWatermarkFrameworks.isEmpty {
			try await WatermarkRemover.apply(frameworks: _options.removeWatermarkFrameworks, to: movedAppPath)
		}
		// #41 remove export limits: raise local caps / switch
		// local limit gates off.
		if !_options.removeExportLimitChanges.isEmpty {
			try await AppConfigApplier.apply(changes: _options.removeExportLimitChanges, to: movedAppPath)
		}
		// #42 remove subscription screen: hide the locally-shown
		// screen only — server-verified premium stays locked.
		if !_options.removeSubscriptionScreenChanges.isEmpty {
			try await AppConfigApplier.apply(changes: _options.removeSubscriptionScreenChanges, to: movedAppPath)
		}
		// #43 stop forced in-app updates: switch local force flags
		// off / lower local minimum versions.
		if !_options.stopForcedUpdateChanges.isEmpty {
			try await AppConfigApplier.apply(changes: _options.stopForcedUpdateChanges, to: movedAppPath)
		}

		// Zenith v2.12, item 19 (#60): write the chosen location
		// override into the copied .app. The file alone does
		// nothing — a location-spoof tweak dylib reads it at runtime.
		try LocationSpoofWriter.apply(selection: _options.locationSpoof, to: movedAppPath)
		// Zenith v2.12, item 20 (#61): flip local login/onboarding
		// gates.
		if !_options.guestLoginChanges.isEmpty {
			try AppConfigApplier.apply(changes: _options.guestLoginChanges, to: movedAppPath)
		}
		// Zenith v2.12, item 21 (#64): force local theme keys to
		// dark. (UIUserInterfaceStyle=Dark itself is already set
		// from options.appAppearance by _modifyDict.)
		if !_options.forceDarkModeChanges.isEmpty {
			try AppConfigApplier.apply(changes: _options.forceDarkModeChanges, to: movedAppPath)
		}
		// Zenith v2.12, item 22 (#79): write the user's typed
		// translations into the copied .app's .strings tables.
		if !_options.translationPlan.edits.isEmpty {
			try AppTranslationApplier.apply(edits: _options.translationPlan.edits, to: movedAppPath)
		}
		
		// iOS "26" (19) needs special treatment
		try await _locateMachosAndFixupArm64eSlice(for: movedAppPath)
		
		if _options.mergeEntitlements && _options.appEntitlementsFile == nil {
			try await _mergeEntitlements(for: movedAppPath, with: _options)
		}
		
		let handler = ZsignHandler(appUrl: movedAppPath, options: _options, cert: appCertificate)
		try await handler.disinject()
		
		if
			_options.signingOption == .default,
			appCertificate != nil
		{
			try await handler.sign()
//		} else if _options.signingOption == .adhoc {
//			try await handler.adhocSign()
		} else if _options.signingOption == .onlyModify {
			//
		} else {
			throw SigningFileHandlerError.missingCertifcate
		}
		
		try await self.move()
		try await self.addToDatabase()
		
		if let error = handler.hadError {
			throw error
		}
	}
	
	func move() async throws {
		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}
		
		var destinationURL = try await _directory()
		
		try _fileManager.createDirectoryIfNeeded(at: destinationURL)
		
		destinationURL = destinationURL.appendingPathComponent(movedAppPath.lastPathComponent)
		
		try _fileManager.moveItem(at: movedAppPath, to: destinationURL)
		Logger.misc.info("[\(self._uuid)] Moved App to: \(destinationURL.path)")
		
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}
	
	func addToDatabase() async throws {
		let app = try await _directory()
		
		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			return
		}
		
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			let bundle = Bundle(url: appUrl)
			
			Storage.shared.addSigned(
				uuid: _uuid,
				source: _app.source,
				certificate: _options.signingOption != .default ? nil : appCertificate,
				appName: bundle?.name,
				appIdentifier: bundle?.bundleIdentifier,
				appVersion: bundle?.version,
				appIcon: bundle?.iconFileName
			) { _ in
				Logger.signing.info("[\(self._uuid)] Added to database")
				continuation.resume()
			}
		}
	}
	
	private func _directory() async throws -> URL {
		// Documents/Zenith/Signed/\(UUID)
		_fileManager.signed(_uuid)
	}
	
	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}
}

extension SigningHandler {
	private func _modifyDict(using infoDictionary: NSMutableDictionary, with options: Options, to app: URL) async throws {
		if options.fileSharing { infoDictionary.setObject(true, forKey: "UISupportsDocumentBrowser" as NSCopying) }
		if options.itunesFileSharing { infoDictionary.setObject(true, forKey: "UIFileSharingEnabled" as NSCopying) }
		if options.proMotion { infoDictionary.setObject(true, forKey: "CADisableMinimumFrameDurationOnPhone" as NSCopying) }
		if options.gameMode { infoDictionary.setObject(true, forKey: "GCSupportsGameMode" as NSCopying)}
		if options.ipadFullscreen { infoDictionary.setObject(true, forKey: "UIRequiresFullScreen" as NSCopying) }
		if options.removeURLScheme { infoDictionary.removeObject(forKey: "CFBundleURLTypes") }
		
		if options.appAppearance != .default {
			infoDictionary.setObject(options.appAppearance.rawValue, forKey: "UIUserInterfaceStyle" as NSCopying)
		}
		if options.minimumAppRequirement != .default {
			infoDictionary.setObject(options.minimumAppRequirement.rawValue, forKey: "MinimumOSVersion" as NSCopying)
		}
		
		if options.experiment_disableLiquidGlass { infoDictionary.setObject(true, forKey: "UIDesignRequiresCompatibility" as NSCopying) }
		if options.experiment_supportLiquidGlass { infoDictionary.setObject(false, forKey: "UIDesignRequiresCompatibility" as NSCopying) }
		
		// useless crap
		if infoDictionary["UISupportedDevices"] != nil {
			infoDictionary.removeObject(forKey: "UISupportedDevices")
		}
		
		// MARK: Prominant values
		
		if let customIdentifier = options.appIdentifier {
			infoDictionary.setObject(customIdentifier, forKey: "CFBundleIdentifier" as NSCopying)
		}
		if let customName = options.appName {
			infoDictionary.setObject(customName, forKey: "CFBundleDisplayName" as NSCopying)
			infoDictionary.setObject(customName, forKey: "CFBundleName" as NSCopying)
		}
		if let customVersion = options.appVersion {
			infoDictionary.setObject(customVersion, forKey: "CFBundleShortVersionString" as NSCopying)
			infoDictionary.setObject(customVersion, forKey: "CFBundleVersion" as NSCopying)
		}
		
		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _modifyDict(using infoDictionary: NSMutableDictionary, for image: UIImage, to app: URL) async throws {
		let imageSizes = [
			(width: 120, height: 120, name: "FRIcon60x60@2x.png"),
			(width: 152, height: 152, name: "FRIcon76x76@2x~ipad.png")
		]
		
		for imageSize in imageSizes {
			let resizedImage = image.resize(imageSize.width, imageSize.height)
			let imageData = resizedImage.pngData()
			let fileURL = app.appendingPathComponent(imageSize.name)
			
			try imageData?.write(to: fileURL)
		}
		
		let cfBundleIcons: [String: Any] = [
			"CFBundlePrimaryIcon": [
				"CFBundleIconFiles": ["FRIcon60x60"],
				"CFBundleIconName": "FRIcon"
			]
		]
		
		let cfBundleIconsIpad: [String: Any] = [
			"CFBundlePrimaryIcon": [
				"CFBundleIconFiles": ["FRIcon60x60", "FRIcon76x76"],
				"CFBundleIconName": "FRIcon"
			]
		]
		
		infoDictionary["CFBundleIcons"] = cfBundleIcons
		infoDictionary["CFBundleIcons~ipad"] = cfBundleIconsIpad
		
		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _modifyLocalesForName(_ name: String, for app: URL) async throws {
		let localizationBundles = try _fileManager
			.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "lproj" }
		
		localizationBundles.forEach { bundleURL in
			let plistURL = bundleURL.appendingPathComponent("InfoPlist.strings")
			
			guard
				_fileManager.fileExists(atPath: plistURL.path),
				let dictionary = NSMutableDictionary(contentsOf: plistURL)
			else {
				return
			}
			
			dictionary["CFBundleDisplayName"] = name
			dictionary.write(toFile: plistURL.path, atomically: true)
		}
	}
	
	private func _modifyPluginIdentifiers(
		old oldIdentifier: String,
		new newIdentifier: String,
		for app: URL
	) async throws {
		let pluginBundles = _enumerateFiles(at: app) {
			$0.hasSuffix(".app") || $0.hasSuffix(".appex")
		}
		
		for bundleURL in pluginBundles {
			let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
			
			guard let infoDict = NSDictionary(contentsOf: infoPlistURL)?.mutableCopy() as? NSMutableDictionary else {
				continue
			}
			
			var didChange = false
			
			// CFBundleIdentifier
			if let oldValue = infoDict["CFBundleIdentifier"] as? String {
				let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
				if oldValue != newValue {
					infoDict["CFBundleIdentifier"] = newValue
					didChange = true
				}
			}
			
			// WKCompanionAppBundleIdentifier
			if let oldValue = infoDict["WKCompanionAppBundleIdentifier"] as? String {
				let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
				if oldValue != newValue {
					infoDict["WKCompanionAppBundleIdentifier"] = newValue
					didChange = true
				}
			}
			if let extensionDict = (infoDict["NSExtension"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary {
				// NSExtension → NSExtensionAttributes → WKAppBundleIdentifier
				if
					let attributes = extensionDict["NSExtensionAttributes"] as? NSMutableDictionary,
					let oldValue = attributes["WKAppBundleIdentifier"] as? String
				{
					let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
					if oldValue != newValue {
						attributes["WKAppBundleIdentifier"] = newValue
						didChange = true
					}
				}
                
				// NSExtension → NSExtensionFileProviderDocumentGroup
				if
					let oldValue = extensionDict["NSExtensionFileProviderDocumentGroup"] as? String
				{
					let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
					if oldValue != newValue {
						extensionDict["NSExtensionFileProviderDocumentGroup"] = newValue
						didChange = true
					}
				}
                
				infoDict["NSExtension"] = extensionDict
			}
			
			if didChange {
				infoDict.write(to: infoPlistURL, atomically: true)
			}
		}
	}
	
	private func _removePresetFiles(for app: URL) async throws {
		var files = [
			"_CodeSignature", // Fallbaccck for some reason the locate doesnt work
			"embedded.mobileprovision", // Remove this because zsign doesn't replace it
			"com.apple.WatchPlaceholder", // Useless
			"SignedByEsign" // Useless
		].map {
			app.appendingPathComponent($0)
		}
		
		await files += try _locateCodeSignatureDirectories(for: app)
		
		for file in files {
			try _fileManager.removeFileIfNeeded(at: file)
		}
	}
	
	// horrible edge-case
	private func _removeWatchIfNeeded(for app: URL) async throws {
		let watchDir = app.appendingPathComponent("Watch")
		guard _fileManager.fileExists(atPath: watchDir.path) else { return }
		
		let contents = try _fileManager.contentsOfDirectory(at: watchDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
		
		for app in contents where app.pathExtension == "app" {
			let infoPlist = app.appendingPathComponent("Info.plist")
			if !_fileManager.fileExists(atPath: infoPlist.path) {
				try? _fileManager.removeItem(at: app)
			}
		}
	}
	
	private func _removeFiles(for app: URL, from appendingComponent: [String]) async throws {
		let filesToRemove = appendingComponent.map {
			app.appendingPathComponent($0)
		}
		
		for url in filesToRemove {
			try _fileManager.removeFileIfNeeded(at: url)
		}
	}
	
	private func _inject(for app: URL, with options: Options) async throws {
		let handler = TweakHandler(app: app, options: options)
		try await handler.getInputFiles()
	}
	
	private func _locateMachosAndChangeToSDK26(for app: URL) async throws {
		if let url = Bundle(url: app)?.executableURL {
			LCPatchMachOForSDK26(app.appendingPathComponent(url.relativePath).relativePath)
		}
	}
	
	private func _locateCodeSignatureDirectories(for app: URL) async throws -> [URL] {
		_enumerateFiles(at: app) { $0.hasSuffix("_CodeSignature") }
	}
	
	// this is mainly for CydiaSubstrate where it often contains legacy arm64e slices
	// which cause the app to crash when loaded on ios 26+,
	// avoids `(cpu type/subtype in slice (arm64e.old) does not match fat header (arm64e))`
	private func _locateMachosAndFixupArm64eSlice(for app: URL) async throws {
		let machoFiles = _enumerateFiles(at: app) {
			$0.hasSuffix(".dylib") || $0.hasSuffix(".framework")
		}
		
		for fileURL in machoFiles {
			switch fileURL.pathExtension {
			case "dylib":
				LCPatchMachOFixupARM64eSlice(fileURL.path)
			case "framework":
				if
					let bundle = Bundle(url: fileURL),
					let execURL = bundle.executableURL
				{
					LCPatchMachOFixupARM64eSlice(execURL.path)
				}
			default:
				continue
			}
		}
	}
	
	// shit ass code
	private func _mergeEntitlements(for app: URL, with options: Options) async throws {
		guard let appBinPath = Bundle(url: app)?.executableURL else {
			throw SigningFileHandlerError.appNotFound
		}
		
		guard 
			let binaryProfile = LCGetMachOEntitlements(appBinPath.path),
			let binaryEntitlementsDict = (try? PropertyListSerialization.propertyList(
				from: binaryProfile,
				options: [],
				format: nil
			)) as? [String: Any]
		else {
			return
		}
		
		guard 
			let cert = self.appCertificate, 
			let ourEntitlements = CertificateReader(Storage.shared.getFile(.provision, from: cert)).decoded
		else {
			return 
		}
		
		let ourTeamIdentifier = ourEntitlements.TeamIdentifier[0]
		let ourBundleIdentifer = options.appIdentifier ?? _app.identifier
		
		var baseDictionary: [String: Any] = (ourEntitlements.Entitlements ?? [:]).mapValues { $0.value }
		let additionsDictionary: [String: Any] = binaryEntitlementsDict

		
		// replaces wildcards in base entitlements with new application id
		// aggressive approach though, lets just hope this works :)
		if let ourBundleIdentifer {
			func replaceWildcards(in value: Any, with newAppID: String) -> Any {
				if let stringValue = value as? String {
					return stringValue.replacingOccurrences(of: "*", with: newAppID)
				} else if let arrayValue = value as? [Any] {
					return arrayValue.map { replaceWildcards(in: $0, with: newAppID) }
				} else if let dictValue = value as? [String: Any] {
					return dictValue.mapValues { replaceWildcards(in: $0, with: newAppID) }
				} else if let anyCodable = value as? AnyCodable {
					let substituted = replaceWildcards(in: anyCodable.value, with: newAppID)
					return AnyCodable(substituted)
				}
				return value
			}
			
			baseDictionary = baseDictionary.reduce(into: [:]) { result, entry in
				let (key, value) = entry

				if 
					key == "com.apple.developer.associated-domains" ||
					key == "application.identifier"
				{
					result[key] = value
					return
				}

				result[key] = replaceWildcards(
					in: value,
					with: ourBundleIdentifer
				)
			}
		}
		
		// this will not consider app extensions, zsign doesnt have functionality be more specific
		// with provisioning profiles, this works fine for impactors "Only register main bundle" though.
		if let keychainGroups = additionsDictionary["keychain-access-groups"] as? [Any] {
			baseDictionary["keychain-access-groups"] = keychainGroups
		}
		
		let regex = try NSRegularExpression(pattern: "^[A-Z0-9]{10}\\.")
		
		if let groups = baseDictionary["keychain-access-groups"] as? [String] {
			// remove anything that does not match XXXXXXXXXX. (for example, com.apple.token)
			// only XXXXXXXXXX.* is allowed on keychain-access-groups
			let validGroups = groups.filter { group in
				let range = NSRange(location: 0, length: group.utf16.count)
				return regex.firstMatch(in: group, options: [], range: range) != nil
			}
			
			let updatedGroups = validGroups.map { group -> String in
				let range = NSRange(location: 0, length: group.utf16.count)
				if regex.firstMatch(in: group, options: [], range: range) != nil && group.count >= 11 {
					let suffix = group.suffix(from: group.index(group.startIndex, offsetBy: 11))
					return "\(ourTeamIdentifier).\(suffix)"
				}
				return group
			}
			
			baseDictionary["keychain-access-groups"] = updatedGroups
		}
		
		let plistData = try PropertyListSerialization.data(
			fromPropertyList: baseDictionary,
			format: .xml,
			options: 0
		)

		let tempEntitlementsURL = _uniqueWorkDir
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension("plist")
		
		try plistData.write(to: tempEntitlementsURL, options: .atomic)
		
		_options.appEntitlementsFile = tempEntitlementsURL
	}
	
	private func _enumerateFiles(at base: URL, where predicate: (String) -> Bool) -> [URL] {
		guard let fileEnum = _fileManager.enumerator(atPath: base.path) else {
			return []
		}
		
		var results: [URL] = []
		
		while let file = fileEnum.nextObject() as? String {
			if predicate(file) {
				results.append(base.appendingPathComponent(file))
			}
		}
		
		return results
	}
}

enum SigningFileHandlerError: Error, LocalizedError {
	case appNotFound
	case infoPlistNotFound
	case missingCertifcate
	case disinjectFailed
	case signFailed
	
	var errorDescription: String? {
		switch self {
		case .appNotFound: "Unable to locate bundle path."
		case .infoPlistNotFound: "Unable to locate info.plist path."
		case .missingCertifcate: "No certificate was specified."
		case .disinjectFailed: "Removing mach-O load paths failed."
		case .signFailed: "Signing failed."
		}
	}
}
