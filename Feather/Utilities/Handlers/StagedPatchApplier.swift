//
//  StagedPatchApplier.swift
//  Zenith
//
//  Phase 1 container — import-time patching, used by the guest
//  importer (ZenithGuestImporter). One source of truth for the
//  staged file-based mod patches, extracted from the patch
//  order SigningHandler.modify used: the same appliers, the
//  same order, the same guards — a patch that applies at
//  signing time applies identically at import time, and is
//  covered by the fresh signature either way. NOTE
//  (additive-only re-scope): SigningHandler was restored to
//  v2.13 and keeps its OWN inline copy of this block — this
//  file is NOT shared with the signing flow anymore. The two
//  copies must be kept in step by hand if either changes.
//
//  What lives here — and what does NOT:
//  - YES: display name / version into Info.plist, every staged
//    mod-file / SDK-strip / config patch, signature-artifact
//    strip, ARM64e slice fixup, dylib staging.
//  - NO: bundle-identifier rewrite (the guest keeps its
//    original id — see ZenithGuestImporter), dylib INJECTION
//    (no load-command patch in Phase 1 — the injected dylib
//    is what crashed the game), entitlements merge, signing
//    itself.
//

import Foundation
import OSLog

// MARK: - Staged patch applier
enum StagedPatchApplier {

	// MARK: Identity (guest import only)

	/// Writes the chosen display name / version into the
	/// guest's Info.plist (plus every *.lproj
	/// InfoPlist.strings for the name) — the same
	/// prominent-values edit SigningHandler._modifyDict makes
	/// for the old flow. The bundle ID is DELIBERATELY never
	/// touched here: the guest keeps its original identifier
	/// (the Library record and the guest folder both key off
	/// it), and zsign's bundle-id parameter would rewrite it.
	static func applyIdentity(options: Options, to appDirectory: URL) throws {
		guard options.appName != nil || options.appVersion != nil else { return }
		let infoPlistURL = appDirectory.appendingPathComponent("Info.plist")
		guard
			let infoDictionary = NSDictionary(contentsOf: infoPlistURL)?.mutableCopy() as? NSMutableDictionary
		else {
			return
		}
		if let name = options.appName {
			infoDictionary.setObject(name, forKey: "CFBundleDisplayName" as NSCopying)
			infoDictionary.setObject(name, forKey: "CFBundleName" as NSCopying)
		}
		if let version = options.appVersion {
			infoDictionary.setObject(version, forKey: "CFBundleShortVersionString" as NSCopying)
			infoDictionary.setObject(version, forKey: "CFBundleVersion" as NSCopying)
		}
		try infoDictionary.write(to: infoPlistURL)
		if let name = options.appName {
			try _modifyLocalesForName(name, for: appDirectory)
		}
	}

	private static func _modifyLocalesForName(_ name: String, for app: URL) throws {
		let localizationBundles = try FileManager.default
			.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "lproj" }
		localizationBundles.forEach { bundleURL in
			let plistURL = bundleURL.appendingPathComponent("InfoPlist.strings")
			guard
				FileManager.default.fileExists(atPath: plistURL.path),
				let dictionary = NSMutableDictionary(contentsOf: plistURL)
			else {
				return
			}
			dictionary["CFBundleDisplayName"] = name
			dictionary.write(toFile: plistURL.path, atomically: true)
		}
	}

	// MARK: Mod patches (shared with SigningHandler.modify)

	/// Applies every staged file-based mod patch to a copied
	/// .app, in the exact order SigningHandler.modify used.
	/// Each applier re-verifies its staged entries against the
	/// bundle and throws on the first entry that cannot be
	/// applied — a half-patched set is never signed.
	static func applyModPatches(options: Options, to appDirectory: URL) throws {
		// Zenith v2.12, item 4: apply the user's staged local-file
		// edits (money, points, ...) to the copied .app before
		// re-signing, so the edited files are covered by the fresh
		// signature. Throws on the first bad edit — a half-applied
		// set is never silently signed.
		if !options.modFileEdits.isEmpty {
			try ModFileEditor.apply(edits: options.modFileEdits, to: appDirectory)
		}

		// Zenith v2.12, item 8 (#23): strip the ad SDK frameworks
		// the user chose — only ones the detector verified as
		// unlinked, so the app still launches. Throws on the first
		// framework that cannot be removed safely, so a
		// half-stripped app is never signed.
		if !options.removeAdsSDKs.isEmpty {
			try AdSDKRemover.apply(frameworks: options.removeAdsSDKs, to: appDirectory)
		}
		// Zenith v2.12, item 23 (#100): strip the files the user
		// chose for the Lite version — only ones the detector
		// proved safe to remove; re-verified at signing time.
		if !options.liteStripPaths.isEmpty {
			try LiteStripRemover.apply(paths: options.liteStripPaths, to: appDirectory)
		}
		// Zenith v2.12, item 9 (#24): enable the hidden
		// developer-menu flags the user chose.
		if !options.devMenuChanges.isEmpty {
			try DevMenuApplier.apply(changes: options.devMenuChanges, to: appDirectory)
		}
		// Zenith v2.12, item 17 (#45): replace bundled fonts with
		// the user-supplied font files (same file names, so
		// UIAppFonts keeps working).
		if !options.fontReplacements.isEmpty {
			try AppFontApplier.apply(replacements: options.fontReplacements, to: appDirectory)
		}
		// Zenith v2.12, item 18 (#46): shorten local animation
		// durations (original × 0.5).
		if !options.animationDurationChanges.isEmpty {
			try AnimationSpeedApplier.apply(changes: options.animationDurationChanges, to: appDirectory)
		}

		// Zenith v2.12, items 13-16 (#40-#43): apply the staged
		// app-modding patches to the copied .app before re-signing,
		// so they are covered by the fresh signature. Each applier
		// re-verifies its staged entries against the copied bundle
		// and throws on the first entry that cannot be applied —
		// a half-patched set is never silently signed.
		// #40 remove watermark: local config changes first, then
		// the proven-unlinked watermark frameworks.
		if !options.removeWatermarkChanges.isEmpty {
			try AppConfigApplier.apply(changes: options.removeWatermarkChanges, to: appDirectory)
		}
		if !options.removeWatermarkFrameworks.isEmpty {
			try WatermarkRemover.apply(frameworks: options.removeWatermarkFrameworks, to: appDirectory)
		}
		// #41 remove export limits: raise local caps / switch
		// local limit gates off.
		if !options.removeExportLimitChanges.isEmpty {
			try AppConfigApplier.apply(changes: options.removeExportLimitChanges, to: appDirectory)
		}
		// #42 remove subscription screen: hide the locally-shown
		// screen only — server-verified premium stays locked.
		if !options.removeSubscriptionScreenChanges.isEmpty {
			try AppConfigApplier.apply(changes: options.removeSubscriptionScreenChanges, to: appDirectory)
		}
		// #43 stop forced in-app updates: switch local force flags
		// off / lower local minimum versions.
		if !options.stopForcedUpdateChanges.isEmpty {
			try AppConfigApplier.apply(changes: options.stopForcedUpdateChanges, to: appDirectory)
		}

		// Zenith v2.12, item 19 (#60): write the chosen location
		// override into the copied .app. The file alone does
		// nothing — a location-spoof tweak dylib reads it at runtime.
		try LocationSpoofWriter.apply(selection: options.locationSpoof, to: appDirectory)
		// Zenith v2.12, item 20 (#61): flip local login/onboarding
		// gates.
		if !options.guestLoginChanges.isEmpty {
			try AppConfigApplier.apply(changes: options.guestLoginChanges, to: appDirectory)
		}
		// Zenith v2.12, item 21 (#64): force local theme keys to
		// dark. (UIUserInterfaceStyle=Dark itself is already set
		// from options.appAppearance by _modifyDict.)
		if !options.forceDarkModeChanges.isEmpty {
			try AppConfigApplier.apply(changes: options.forceDarkModeChanges, to: appDirectory)
		}
		// Zenith v2.12, item 22 (#79): write the user's typed
		// translations into the copied .app's .strings tables.
		if !options.translationPlan.edits.isEmpty {
			try AppTranslationApplier.apply(edits: options.translationPlan.edits, to: appDirectory)
		}
	}

	// MARK: Signature artifacts + Mach-O

	/// Removes the old signature and provision before the fresh
	/// sign (same set SigningHandler._removePresetFiles removes).
	/// A stale _CodeSignature would otherwise shadow the new
	/// one, and a foreign embedded.mobileprovision must never
	/// survive into the guest.
	static func stripSignatureArtifacts(in appDirectory: URL) throws {
		let fileManager = FileManager.default
		var files = [
			"_CodeSignature",
			"embedded.mobileprovision",
			"com.apple.WatchPlaceholder",
			"SignedByEsign"
		].map {
			appDirectory.appendingPathComponent($0)
		}
		files += _enumerateFiles(at: appDirectory) { $0.hasSuffix("_CodeSignature") }
		for file in files {
			try fileManager.removeFileIfNeeded(at: file)
		}
	}

	/// Fixes the arm64e slice of the main executable and every
	/// bundled .dylib / .framework (same helper the old flow
	/// uses, plus the main executable itself — the one that
	/// must load). CydiaSubstrate-era arm64e slices crash on
	/// iOS 26+ without this.
	static func fixupARM64eSlices(in appDirectory: URL) {
		if let execURL = Bundle(url: appDirectory)?.executableURL {
			LCPatchMachOFixupARM64eSlice(execURL.path)
		}
		for fileURL in _enumerateFiles(at: appDirectory, where: { $0.hasSuffix(".dylib") || $0.hasSuffix(".framework") }) {
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

	// MARK: Dylib staging (Phase 1: copy only, never inject)

	/// Copies staged .dylib files into the guest's Frameworks/
	/// WITHOUT adding any load command to the executable — no
	/// TweakLoader in Phase 1. The names are recorded in
	/// LCAppInfo.plist (ZenithStagedDylibs) so the later
	/// in-process loader knows what is staged. .deb files are
	/// skipped (they need AR extraction + injection) and
	/// counted, so the import screen can say so honestly.
	/// Returns the staged file names and the skipped .deb count.
	@discardableResult
	static func stageDylibs(_ files: [URL], to appDirectory: URL) throws -> (staged: [String], skippedDebs: Int) {
		guard !files.isEmpty else { return ([], 0) }
		let fileManager = FileManager.default
		let frameworksDir = appDirectory.appendingPathComponent("Frameworks")
		var staged: [String] = []
		var skippedDebs = 0
		for url in files {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try fileManager.createDirectoryIfNeeded(at: frameworksDir)
				let destination = frameworksDir.appendingPathComponent(url.lastPathComponent)
				try fileManager.removeFileIfNeeded(at: destination)
				// Copy, never move: the source can be the bundled
				// editor dylib inside Zenith itself.
				try fileManager.copyItem(at: url, to: destination)
				staged.append(url.lastPathComponent)
			case "deb":
				skippedDebs += 1
				Logger.misc.warning("Guest import skips .deb \(url.lastPathComponent): needs extraction + injection")
			default:
				Logger.misc.warning("Guest import skips unsupported staged file \(url.lastPathComponent)")
			}
		}
		return (staged, skippedDebs)
	}

	// MARK: Helpers

	private static func _enumerateFiles(at base: URL, where predicate: (String) -> Bool) -> [URL] {
		guard let fileEnum = FileManager.default.enumerator(atPath: base.path) else {
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
