//
//  DylibHandler.swift
//  zenith
//
//  Created by samara on 8/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Foundation
import Zsign
import OSLog

class TweakHandler {
	private let _fileManager = FileManager.default
	private var _urlsToInject: [URL] = []
	private var _directoriesToCheck: [URL] = []
	private var _injectedDylibNames: [String] = []

	private let _app: URL
	private var _options: Options
	private var _urls: [URL]

	init(
		app: URL,
		options: Options = OptionsManager.shared.options
	) {
		self._app = app
		self._options = options
		self._urls = options.injectionFiles
	}
	
	private func _checkEllekit() async throws {
		let frameworksPath = _app.appendingPathComponent("Frameworks").appendingPathComponent("CydiaSubstrate.framework")

		func addEllekit() async throws {
			if let ellekitURL = Bundle.main.url(forResource: "ellekit", withExtension: "deb") {
				self._urls.insert(ellekitURL, at: 0)
			} else {
				Logger.misc.info("ellekit.deb not found in the app bundle")
			}
			
			try _fileManager.createDirectoryIfNeeded(at: _app.appendingPathComponent("Frameworks"))
		}
		// we should check if CydiaSubstrate.framework exists, if it doesn't
		// just add ellekit
		// experiment_replaceSubstrateWithEllekit:
		// 	for this version, we need to replace CydiaSubstrate.framework with
		//	our own version containing ElleKit
		// other:
		// 	just return if it exists, should work fine
		if _fileManager.fileExists(atPath: frameworksPath.path) {
			if _options.experiment_replaceSubstrateWithEllekit {
				Logger.misc.info("Attempting to replace Substrate with ElleKit")
				try _fileManager.removeFileIfNeeded(at: frameworksPath)
				try await addEllekit()
			} else {
				return
			}
		} else {
			guard !_urls.isEmpty else { return }
			try await addEllekit()
		}
	}

	public func getInputFiles() async throws {
		Logger.misc.info("Attempting to inject")
		
		if !_options.experiment_replaceSubstrateWithEllekit {
			guard !_urls.isEmpty else { return }
		}

		try await _checkEllekit()

		let baseTmpDir = _fileManager.temporaryDirectory.appendingPathComponent("ZenithTweak_\(UUID().uuidString)")
		try _fileManager.createDirectoryIfNeeded(at: baseTmpDir)
		
		// check for appropriate files, if theres debs
		// it will extract then add a url, if theres no url, i.e.
		// you haven't added a deb, it will skip
		for url in _urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "deb":
				try await _handleDeb(at: url, baseTmpDir: baseTmpDir)
			default:
				Logger.misc.warning("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}
		
		// check contents of data.tar's extracted from debs
		if !_directoriesToCheck.isEmpty {
			try await _handleDirectories(at: _directoriesToCheck)
			if !_urlsToInject.isEmpty {
				try await _handleExtractedDirectoryContents(at: _urlsToInject)
			}
		}

		// inject into all extensions if enabled
		if _options.injectIntoExtensions && !_injectedDylibNames.isEmpty {
			_injectIntoAllExtensions(dylibNames: _injectedDylibNames)
		}
	}
	
	// finally, handle extracted contents
	private func _handleExtractedDirectoryContents(at urls: [URL]) async throws {
		for url in urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "framework":
				let destinationURL = _app.appendingPathComponent("Frameworks").appendingPathComponent(url.lastPathComponent)
				try _fileManager.moveFileIfNeeded(from: url, to: destinationURL)
				try await _handleDylib(framework: destinationURL)
			case "bundle":
				let destinationURL = _app.appendingPathComponent(url.lastPathComponent)
				try _fileManager.moveFileIfNeeded(from: url, to: destinationURL)
			default:
				Logger.misc.warning("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}
	}
	
	// Inject imported dylib file
	private func _handleDylib(at url: URL) async throws {
		var destinationURL = _app
		var injectFolder = _options.injectFolder
		
		// check for "/Frameworks/", then append the destinationUrl
		if _options.injectFolder == .frameworks {
			destinationURL = destinationURL.appendingPathComponent("Frameworks")
		}
		
		// We check for "@rpath" and "/Frameworks/", if they're both enabled force
		// the inject folder to be root "/" instead, as the @rpath is already in
		// frameworks
		if
			_options.injectPath == .rpath && _options.injectFolder == .frameworks
		{
			injectFolder = .root
		}
		
		destinationURL = destinationURL.appendingPathComponent(url.lastPathComponent)
		
		// Zenith v2.20: a re-sign of an already-injected IPA must
		// replace the dylib already in the bundle. moveFileIfNeeded
		// silently skips when the destination exists, so the OLD
		// dylib stayed in the game and the new build never reached
		// it (proven 2026-11-28: the dylib inside the game had the
		// identical UUID across 2.18 and 2.19 signings). The load
		// command itself is safe on re-injection: zsign's
		// InjectDylib no-ops when the same path is already loaded.
		// Zenith v2.24: COPY the staged dylib into the bundle, do
		// not move it. The move consumed the staged file, but its
		// URL stays in the persisted Options (OptionsManager saves
		// injectionFiles) — the next signing then found a dangling
		// staged URL, refreshStagedBundledOverlays silently skipped
		// it, and the remove above deleted the old dylib from the
		// copied bundle before the move threw on the missing file,
		// so re-signing with the overlays on always failed after
		// the first signing. A copy leaves the staged file in place
		// for the next signing, where refresh keeps its bytes
		// current.
		if url != destinationURL {
			try _fileManager.removeFileIfNeeded(at: destinationURL)
			try _fileManager.copyItem(at: url, to: destinationURL)
		}
		
		guard let appexe = Bundle(url: _app)?.executableURL else {
			return
		}
		
		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_ = Zsign.changeDylibPath(
			appExecutable: destinationURL.path,
			for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
		)
		// inject if there's a valid app main executable
		_ = Zsign.injectDyLib(
			appExecutable: appexe.path,
			with: "\(_options.injectPath.rawValue)\(injectFolder.rawValue)\(destinationURL.lastPathComponent)"
		)

		_injectedDylibNames.append(destinationURL.lastPathComponent)
	}
	
	// Inject imported framework dir
	private func _handleDylib(framework: URL) async throws {
		guard
			let fexe = Bundle(url: framework)?.executableURL,
			let appexe = Bundle(url: _app)?.executableURL
		else {
			return
		}
		
		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_ = Zsign.changeDylibPath(
			appExecutable: fexe.path,
			for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
		)
		// inject if there's a valid app main executable
		_ = Zsign.injectDyLib(
			appExecutable: appexe.path,
			with: "@executable_path/Frameworks/\(framework.lastPathComponent)/\(fexe.lastPathComponent)"
		)
	}
	
	// Extracy imported deb file
	private func _handleDeb(at url: URL, baseTmpDir: URL) async throws {
		let uniqueSubDir = baseTmpDir.appendingPathComponent(UUID().uuidString)
		try _fileManager.createDirectoryIfNeeded(at: uniqueSubDir)
		
		// I don't particularly like this code
		// but it somehow works well enough,
		// do note large lzma's are slow as hell
		
		let handler = AR(with: url)
		let arFiles = try await handler.extract()
		
		for arFile in arFiles {
			let outputPath = uniqueSubDir.appendingPathComponent(arFile.name)
			try arFile.content.write(to: outputPath)
			
			if ["data.tar.lzma", "data.tar.gz", "data.tar.xz", "data.tar.bz2"].contains(arFile.name) {
				var fileToProcess = outputPath
				try extractFile(at: &fileToProcess)
				try extractFile(at: &fileToProcess)
				_directoriesToCheck.append(fileToProcess)
			}
		}
	}
	
	// Read extracted deb file, locate all neccessary contents to copy over to the .app
	private func _handleDirectories(at urls: [URL]) async throws {
		enum DirectoryType: String {
			case frameworks = "Frameworks"
			case dynamicLibraries = "MobileSubstrate/DynamicLibraries"
			case applicationSupport = "Application Support"
		}
		
		let directoryPaths: [DirectoryType: [String]] = [
			.frameworks: ["Library/Frameworks/", "var/jb/Library/Frameworks/"],
			.dynamicLibraries: ["Library/MobileSubstrate/DynamicLibraries/", "var/jb/Library/MobileSubstrate/DynamicLibraries/"],
			.applicationSupport: ["Library/Application Support/", "var/jb/Library/Application Support/"]
		]
				
		for baseURL in urls {
			for (directoryType, paths) in directoryPaths {
				for path in paths {
					let directoryURL = baseURL.appendingPathComponent(path)
					
					guard _fileManager.fileExists(atPath: directoryURL.path) else {
						Logger.misc.warning("Directory does not exist: \(directoryURL.path). Skipping.")
						continue
					}
					
					switch directoryType {
					case .dynamicLibraries:
						let dylibFiles = try await _locateDylibFiles(in: directoryURL)
						_urlsToInject.append(contentsOf: dylibFiles)
						
					case .frameworks:
						let frameworkDirectories = try await _locateFrameworkDirectories(in: directoryURL)
						_urlsToInject.append(contentsOf: frameworkDirectories)
						
					case .applicationSupport:
						try await _searchForBundles(in: directoryURL)
					}
				}
			}
		}
	}

	// Discovers all .appex bundles in the app's PlugIns and Extensions directories
	private func _discoverAppExtensions() -> [URL] {
		var extensions: [URL] = []
		
		let plugInsPath = _app.appendingPathComponent("PlugIns")
		let extensionsPath = _app.appendingPathComponent("Extensions")
		
		for directory in [plugInsPath, extensionsPath] {
			guard _fileManager.fileExists(atPath: directory.path) else { continue }
			
			do {
				let contents = try _fileManager.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: nil,
					options: [.skipsHiddenFiles]
				)
				
				let appexBundles = contents.filter { url in
					url.pathExtension.lowercased() == "appex" && url.hasDirectoryPath
				}
				
				extensions.append(contentsOf: appexBundles)
			} catch {
				Logger.misc.warning("Failed to enumerate \(directory.path): \(error.localizedDescription)")
			}
		}
		
		return extensions
	}

	// Injects a dylib into an extension's executable
	private func _injectIntoExtension(extensionURL: URL, dylibName: String) {
		guard 
			let extensionBundle = Bundle(url: extensionURL),
			let extensionExecutable = extensionBundle.executableURL 
		else {
			Logger.misc.warning("Skipping \(extensionURL.lastPathComponent): couldn't read bundle")
			return
		}
		
		var injectFolder = _options.injectFolder
		if _options.injectPath == .rpath && _options.injectFolder == .frameworks {
			injectFolder = .root
		}
		
		let injectPath: String
		if _options.injectPath == .rpath {
			injectPath = "@rpath/\(dylibName)"
		} else {
			if injectFolder == .frameworks {
				injectPath = "@executable_path/../../Frameworks/\(dylibName)"
			} else {
				injectPath = "@executable_path/../../\(dylibName)"
			}
		}
		
		let success = Zsign.injectDyLib(
			appExecutable: extensionExecutable.path,
			with: injectPath
		)
		
		if success {
			Logger.misc.info("Injected \(dylibName) into extension: \(extensionURL.lastPathComponent)")
		} else {
			Logger.misc.warning("Failed to inject into extension: \(extensionURL.lastPathComponent)")
		}
	}

	// Injects all dylibs into all discovered extensions
	private func _injectIntoAllExtensions(dylibNames: [String]) {
		let extensions = _discoverAppExtensions()

		guard !extensions.isEmpty else {
			Logger.misc.info("No app extensions found for injection")
			return
		}

		Logger.misc.info("Found \(extensions.count) app extension(s) for injection")

		for extensionURL in extensions {
			for dylibName in dylibNames {
				_injectIntoExtension(extensionURL: extensionURL, dylibName: dylibName)
			}
		}
	}

	// Zenith v2.20: refresh the staged copies of the bundled
	// overlay dylibs (Value Editor, FPS counter, in-app
	// translation) before injecting. A staged copy is made ONCE,
	// when its toggle is turned on (FileManager.moveAndStore),
	// and it survives app updates — so without this, signing kept
	// injecting the dylib bytes of whichever Zenith build staged
	// the copy, forever (proven 2026-11-28: the dylib inside the
	// game had the identical UUID across 2.18 and 2.19 signings).
	// Any staged file whose name is exactly a bundled overlay
	// dylib's name gets its bytes overwritten in place with the
	// CURRENT bundled dylib when they differ. User-supplied
	// dylibs (any other file name) are never touched, and the
	// staged URL stays valid — nothing in Options needs to
	// change, so the persisted entry is refreshed too. A missing
	// staged file is re-created from the bundled dylib (v2.24):
	// it is the normal state after an earlier signing consumed
	// the staged copy, and leaving it missing broke the next
	// signing — see the note inside the loop.
	static func refreshStagedBundledOverlays(in options: Options) {
		let bundled: [(name: String, url: URL?)] = [
			(ValueEditorInjector.bundledDylibName, ValueEditorInjector.bundledDylibURL),
			(FPSOverlayInjector.bundledDylibName, FPSOverlayInjector.bundledDylibURL),
			(TranslationOverlayInjector.bundledDylibName, TranslationOverlayInjector.bundledDylibURL),
		]
		for (name, bundledURL) in bundled {
			guard let bundledURL else { continue }
			guard let bundledData = try? Data(contentsOf: bundledURL) else { continue }
			let fileName = name + ".dylib"
			for staged in options.injectionFiles where staged.lastPathComponent == fileName {
				if let stagedData = try? Data(contentsOf: staged), stagedData == bundledData {
					continue
				}
				// Zenith v2.24: a staged copy that is missing (or
				// stale) is re-created from the current bundled
				// dylib instead of skipped. The old code skipped a
				// missing staged file — but a missing staged file is
				// the NORMAL state after any earlier signing, because
				// _handleDylib moved the staged file into the .app
				// and the persisted Options still list its URL. The
				// skip left the next signing with no dylib to inject
				// (and _handleDylib's remove-then-move threw on the
				// missing file), so re-signing with the overlays on
				// always failed after the first signing. The parent
				// directory may be gone too (tmp purge), so recreate
				// it; if either step fails, injection still fails
				// loudly as before instead of signing without the
				// overlay.
				try? FileManager.default.createDirectoryIfNeeded(at: staged.deletingLastPathComponent())
				try? bundledData.write(to: staged, options: .atomic)
				Logger.misc.info("Refreshed staged overlay dylib \(fileName) with the current build's copy")
			}
		}
	}
}

// MARK: - Find correct files in debs
extension TweakHandler {
	private func _searchForBundles(in directory: URL) async throws {
		let fileManager = FileManager.default
		let allFiles = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let bundleDirectories = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "bundle" && url.hasDirectoryPath && !isSymlink
		}
		
		for bundleURL in bundleDirectories {
			_urlsToInject.append(bundleURL)
		}
		
		let directoriesToSearch = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.hasDirectoryPath && !bundleDirectories.contains(url) && !isSymlink
		}
		
		for dirURL in directoriesToSearch {
			try await _searchForBundles(in: dirURL)
		}
	}

	private func _locateDylibFiles(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])

		let dylibFiles = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "dylib" && !isSymlink
		}
		
		return dylibFiles
	}

	private func _locateFrameworkDirectories(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let frameworkDirectories = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "framework" && url.hasDirectoryPath && !isSymlink
		}
		
		return frameworkDirectories
	}
}

enum TweakHandlerError: Error {
	case unsupportedFileExtension(String)
	case decompressionFailed(String)
	case missingFile(String)
	case noAccess
}
