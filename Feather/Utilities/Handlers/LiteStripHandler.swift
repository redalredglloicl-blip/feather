//
//  LiteStripHandler.swift
//  Zenith
//
//  Zenith v2.12, item 23 (#100): Lite version of any app — strip
//  unused files/frameworks from the IPA to shrink it before
//  signing. The LAST item of section 2 "تعديل التطبيقات" on the
//  signing screen, after #79.
//
//  What the scan offers, and only what it can PROVE safe:
//  * A bundled .framework the app does NOT link — linkage is
//    checked against the main executable AND every other binary
//    in the bundle (other frameworks, .dylibs, PlugIns), by
//    parsing Mach-O load commands in pure Swift. A framework
//    whose name also appears as a string inside the main
//    executable is blocked too: it may be loaded dynamically
//    (dlopen / NSBundle) and load commands cannot prove that.
//  * A *.lproj folder that is neither Base.lproj nor the
//    development-region language — language files only, the app
//    falls back to its main language when one is gone.
//  * Junk files the app never reads (.DS_Store, Thumbs.db).
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * A linked framework is never offered: deleting it breaks the
//    app at launch (dyld: Library not loaded), and this toolchain
//    has no Mach-O load-command editor to unlink it.
//  * When any binary's Mach-O header cannot be parsed, linkage
//    is UNKNOWN and no framework is offered at all — never
//    guessed.
//  * Unused images, sounds, videos and other resources are NOT
//    offered: a resource loaded by a name built at runtime looks
//    exactly like an unused one, so its safety cannot be proven.
//  * The main executable, Info.plist, the code signature,
//    embedded.mobileprovision and PlugIns are never offered.
//  * Stripping only shrinks the signed copy; the imported
//    original is untouched. Sizes are the on-disk sizes of the
//    removed files, so the saving is approximate.
//
//  WIRING (coordinator): add `liteStripPaths: [String]` to
//  Options (OptionsManager.swift) with a `[]` default, and call
//  LiteStripRemover from SigningHandler.modify() right after the
//  AdSDKRemover block:
//
//    // Zenith v2.12, item 23 (#100): strip the files the user
//    // chose for the Lite version — only ones the detector
//    // proved safe to remove; re-verified at signing time.
//    if !_options.liteStripPaths.isEmpty {
//        try LiteStripRemover.apply(paths: _options.liteStripPaths, to: movedAppPath)
//    }
//
//  SigningView.swift is NOT edited by this file — the row is
//  LiteVersionRowView in LiteVersionView.swift.
//

import Foundation

// MARK: - Model

/// What kind of Lite-strip candidate this is.
enum LiteStripKind: Equatable {
	/// A whole bundled .framework.
	case unlinkedFramework
	/// A *.lproj language folder.
	case unusedLanguage
	/// A junk file the app never reads.
	case junkFile
}

/// One file or folder the scan looked at.
struct LiteStripCandidate: Identifiable, Equatable {
	var id: String { relativePath }

	/// Path inside the .app, e.g. `Frameworks/Foo.framework`
	/// or `ar.lproj` or `.DS_Store`.
	var relativePath: String
	/// Name shown in the list, e.g. `Foo.framework`.
	var displayName: String
	var kind: LiteStripKind
	/// On-disk size in bytes (recursive for folders).
	var sizeBytes: UInt64
	/// True only when safety was proven — the view offers a
	/// toggle only for these.
	var isRemovable: Bool
	/// Localization key for the one-line reason shown under the
	/// name: why it is safe, or why it cannot be stripped.
	var reasonKey: String
}

/// The outcome of the Lite scan.
struct LiteStripReport: Equatable {
	var items: [LiteStripCandidate]
	/// False when any binary's Mach-O header could not be
	/// parsed, so no framework could be proven unlinked.
	var linkageKnown: Bool
	/// Total on-disk size of the .app, for context.
	var totalAppSizeBytes: UInt64

	var removableItems: [LiteStripCandidate] { items.filter(\.isRemovable) }
	var blockedItems: [LiteStripCandidate] { items.filter { !$0.isRemovable } }
	var removableSizeBytes: UInt64 { removableItems.reduce(0) { $0 + $1.sizeBytes } }
}

// MARK: - Detector

enum LiteStripDetector {
	/// Junk file names the app never reads. Matched on the last
	/// path component, anywhere inside the .app except inside
	/// _CodeSignature.
	static let junkFileNames: Set<String> = [".DS_Store", "Thumbs.db"]

	/// Scans `appDirectory` (a `.app` bundle) for Lite-strip
	/// candidates. Synchronous — call from a background queue.
	static func scan(appDirectory: URL) -> LiteStripReport {
		let fileManager = FileManager.default
		var items: [LiteStripCandidate] = []

		// Development-region language from Info.plist — that
		// .lproj is the app's main language and is never offered.
		let infoPlist = appDirectory.appendingPathComponent("Info.plist")
		let developmentRegion: String = {
			guard
				let data = try? Data(contentsOf: infoPlist),
				let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
				let region = plist["CFBundleDevelopmentRegion"] as? String,
				!region.isEmpty
			else { return "en" }
			return region
		}()

		// 1. Linkage: main executable + every other binary in the
		// bundle. Any binary that cannot be parsed makes linkage
		// UNKNOWN, so no framework is ever offered on a guess.
		let executableURL = Bundle(url: appDirectory)?.executableURL
		var linkedNames = Set<String>()
		var linkageKnown = false
		if let executableURL {
			if let mainLinked = _linkedInstallNames(in: executableURL) {
				linkageKnown = true
				linkedNames.formUnion(mainLinked)
				for binaryURL in _secondaryBinaryURLs(in: appDirectory) {
					guard let names = _linkedInstallNames(in: binaryURL) else {
						linkageKnown = false
						break
					}
					linkedNames.formUnion(names)
				}
			}
		}

		// Framework base names mentioned inside the main
		// executable: a possible dynamic load (dlopen / NSBundle),
		// which load commands cannot prove. Only checked when
		// linkage is known, since it only matters for frameworks
		// that would otherwise be offered.
		var dynamicallyNamed: Set<String> = []
		if linkageKnown, let executableURL {
			let frameworksDir = appDirectory.appendingPathComponent("Frameworks")
			if let entries = try? fileManager.contentsOfDirectory(
				at: frameworksDir,
				includingPropertiesForKeys: [.isDirectoryKey]
			) {
				let baseNames = entries
					.filter { $0.pathExtension.lowercased() == "framework" }
					.map { $0.deletingPathExtension().lastPathComponent }
				dynamicallyNamed = _binaryMarkersFound(in: executableURL, markers: baseNames)
			}
		}

		// 2. Bundled frameworks.
		let frameworksDir = appDirectory.appendingPathComponent("Frameworks")
		if let entries = try? fileManager.contentsOfDirectory(
			at: frameworksDir,
			includingPropertiesForKeys: [.isDirectoryKey]
		) {
			for url in entries where url.pathExtension.lowercased() == "framework" {
				let name = url.lastPathComponent
				let baseName = url.deletingPathExtension().lastPathComponent
				let size = _directorySize(at: url)
				let relativePath = "Frameworks/" + name
				if !linkageKnown {
					items.append(LiteStripCandidate(
						relativePath: relativePath,
						displayName: name,
						kind: .unlinkedFramework,
						sizeBytes: size,
						isRemovable: false,
						reasonKey: "Lite Strip Linkage Unknown"
					))
				} else if linkedNames.contains(where: {
					$0.contains(name) || $0.hasSuffix("/" + baseName)
				}) {
					items.append(LiteStripCandidate(
						relativePath: relativePath,
						displayName: name,
						kind: .unlinkedFramework,
						sizeBytes: size,
						isRemovable: false,
						reasonKey: "Lite Strip Linked"
					))
				} else if dynamicallyNamed.contains(baseName) {
					items.append(LiteStripCandidate(
						relativePath: relativePath,
						displayName: name,
						kind: .unlinkedFramework,
						sizeBytes: size,
						isRemovable: false,
						reasonKey: "Lite Strip Maybe Loaded At Runtime"
					))
				} else {
					items.append(LiteStripCandidate(
						relativePath: relativePath,
						displayName: name,
						kind: .unlinkedFramework,
						sizeBytes: size,
						isRemovable: true,
						reasonKey: "Lite Strip Not Linked"
					))
				}
			}
		}

		// 3. Language folders at the top level of the .app.
		// Base.lproj and the development-region .lproj stay;
		// every other .lproj holds language files only, and the
		// app falls back to its main language without it.
		if let entries = try? fileManager.contentsOfDirectory(
			at: appDirectory,
			includingPropertiesForKeys: [.isDirectoryKey]
		) {
			for url in entries where url.pathExtension.lowercased() == "lproj" {
				let name = url.lastPathComponent
				let language = url.deletingPathExtension().lastPathComponent
				let size = _directorySize(at: url)
				if language == "Base" {
					items.append(LiteStripCandidate(
						relativePath: name,
						displayName: name,
						kind: .unusedLanguage,
						sizeBytes: size,
						isRemovable: false,
						reasonKey: "Lite Strip Base Language"
					))
				} else if language == developmentRegion {
					items.append(LiteStripCandidate(
						relativePath: name,
						displayName: name,
						kind: .unusedLanguage,
						sizeBytes: size,
						isRemovable: false,
						reasonKey: "Lite Strip Main Language"
					))
				} else {
					items.append(LiteStripCandidate(
						relativePath: name,
						displayName: name,
						kind: .unusedLanguage,
						sizeBytes: size,
						isRemovable: true,
						reasonKey: "Lite Strip Unused Language"
					))
				}
			}
		}

		// 4. Junk files anywhere in the .app (except inside the
		// code signature, which is re-signed, not edited).
		if let enumerator = fileManager.enumerator(
			at: appDirectory,
			includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
		) {
			for case let url as URL in enumerator {
				let components = url.pathComponents
				guard !components.contains("_CodeSignature") else { continue }
				guard junkFileNames.contains(url.lastPathComponent) else { continue }
				guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
				      values.isRegularFile == true
				else { continue }
				let relativePath = String(url.path.dropFirst(appDirectory.path.count + 1))
				items.append(LiteStripCandidate(
					relativePath: relativePath,
					displayName: url.lastPathComponent,
					kind: .junkFile,
					sizeBytes: UInt64(values.fileSize ?? 0),
					isRemovable: true,
					reasonKey: "Lite Strip Junk File"
				))
			}
		}

		items.sort {
			if $0.isRemovable != $1.isRemovable { return $0.isRemovable && !$1.isRemovable }
			if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
			return $0.displayName < $1.displayName
		}
		return LiteStripReport(
			items: items,
			linkageKnown: linkageKnown,
			totalAppSizeBytes: _directorySize(at: appDirectory)
		)
	}

	/// Relative paths that may be deleted, as verified by a fresh
	/// scan. The remover uses this instead of trusting a stale
	/// selection.
	static func removableRelativePaths(in appDirectory: URL) -> Set<String> {
		Set(scan(appDirectory: appDirectory).removableItems.map(\.relativePath))
	}

	// MARK: - Binary discovery

	/// Every executable in the bundle besides the main one: each
	/// framework's binary, loose .dylibs, and PlugIns appex
	/// executables. Their load commands matter too — a framework
	/// linked only by another framework still breaks the app if
	/// it is deleted.
	private static func _secondaryBinaryURLs(in appDirectory: URL) -> [URL] {
		let fileManager = FileManager.default
		var urls: [URL] = []

		let frameworksDir = appDirectory.appendingPathComponent("Frameworks")
		if let entries = try? fileManager.contentsOfDirectory(
			at: frameworksDir,
			includingPropertiesForKeys: [.isDirectoryKey]
		) {
			for frameworkURL in entries where frameworkURL.pathExtension.lowercased() == "framework" {
				urls.append(frameworkURL.appendingPathComponent(frameworkURL.deletingPathExtension().lastPathComponent))
			}
			for entry in entries where entry.pathExtension.lowercased() == "dylib" {
				urls.append(entry)
			}
		}

		if let entries = try? fileManager.contentsOfDirectory(
			at: appDirectory,
			includingPropertiesForKeys: [.isDirectoryKey]
		) {
			for entry in entries where entry.pathExtension.lowercased() == "dylib" {
				urls.append(entry)
			}
		}

		let plugInsDir = appDirectory.appendingPathComponent("PlugIns")
		if let entries = try? fileManager.contentsOfDirectory(
			at: plugInsDir,
			includingPropertiesForKeys: [.isDirectoryKey]
		) {
			for appexURL in entries where appexURL.pathExtension.lowercased() == "appex" {
				if let executableURL = Bundle(url: appexURL)?.executableURL {
					urls.append(executableURL)
				}
			}
		}

		return urls.filter { fileManager.fileExists(atPath: $0.path) }
	}

	// MARK: - Sizes

	/// Recursive on-disk size of a file or folder (regular files
	/// only; symlinks and directories contribute 0).
	private static func _directorySize(at url: URL) -> UInt64 {
		let fileManager = FileManager.default
		if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
		   values.isRegularFile == true {
			return UInt64(values.fileSize ?? 0)
		}
		guard let enumerator = fileManager.enumerator(
			at: url,
			includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
		) else { return 0 }
		var total: UInt64 = 0
		for case let fileURL as URL in enumerator {
			guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
			      values.isRegularFile == true
			else { continue }
			total += UInt64(values.fileSize ?? 0)
		}
		return total
	}

	// MARK: - Mach-O linkage parsing

	/// Install names from a binary's LC_LOAD_*_DYLIB commands.
	/// Nil when the file cannot be read or its header cannot be
	/// parsed — callers must treat that as "unknown", never as
	/// "unlinked".
	private static func _linkedInstallNames(in executableURL: URL) -> Set<String>? {
		guard let handle = try? FileHandle(forReadingFrom: executableURL) else { return nil }
		defer { try? handle.close() }

		func read(at offset: UInt64, length: Int) -> [UInt8]? {
			handle.seek(toFileOffset: offset)
			let data = handle.readData(ofLength: length)
			guard !data.isEmpty else { return nil }
			return [UInt8](data)
		}

		guard let magic = read(at: 0, length: 4), magic.count == 4 else { return nil }

		var sliceOffset: UInt64 = 0
		if magic == [0xCA, 0xFE, 0xBA, 0xBE] || magic == [0xBE, 0xBA, 0xFE, 0xCA] {
			// FAT binary. Fields are big-endian for 0xCAFEBABE,
			// little-endian for 0xCAFEBABF (CIGAM).
			let bigEndian = magic[0] == 0xCA
			guard let header = read(at: 0, length: 8), header.count == 8 else { return nil }
			let nfat = Int(_u32(header, 4, bigEndian: bigEndian))
			guard nfat > 0, nfat < 64 else { return nil }
			var fallback: UInt64?
			for i in 0..<nfat {
				guard let arch = read(at: 8 + UInt64(i) * 20, length: 20), arch.count == 20 else { break }
				let cputype = _u32(arch, 0, bigEndian: bigEndian)
				let offset = _u32(arch, 8, bigEndian: bigEndian)
				if fallback == nil { fallback = UInt64(offset) }
				if cputype == 0x0100000C { // CPU_TYPE_ARM64
					sliceOffset = UInt64(offset)
					break
				}
				sliceOffset = fallback ?? 0
			}
			guard sliceOffset != 0 else { return nil }
		} else if magic == [0xCF, 0xFA, 0xED, 0xFE] || magic == [0xCE, 0xFA, 0xED, 0xFE] {
			// Thin 64-bit (0xfeedfacf) or 32-bit (0xfeedface).
			sliceOffset = 0
		} else {
			return nil
		}

		// Load commands live near the start of the slice; 512KB
		// is far more than any real header needs.
		guard let header = read(at: sliceOffset, length: 512 * 1024), header.count >= 32 else { return nil }
		let is64 = _u32le(header, 0) == 0xfeedfacf
		let headerSize = is64 ? 32 : 28
		guard header.count >= headerSize else { return nil }
		let ncmds = Int(_u32le(header, 16))
		guard ncmds > 0, ncmds < 1000 else { return nil }

		var names = Set<String>()
		var cmdOffset = headerSize
		for _ in 0..<ncmds {
			guard cmdOffset + 8 <= header.count else { break }
			let cmd = _u32le(header, cmdOffset) & ~0x80000000 // strip LC_REQ_DYLD
			let cmdsize = Int(_u32le(header, cmdOffset + 4))
			guard cmdsize >= 8, cmdOffset + cmdsize <= header.count else { break }
			// LC_LOAD_DYLIB 0xC, LC_LOAD_WEAK_DYLIB 0x18,
			// LC_REEXPORT_DYLIB 0x1F, LC_LOAD_UPWARD_DYLIB 0x23.
			if cmd == 0x0C || cmd == 0x18 || cmd == 0x1F || cmd == 0x23 {
				let nameOffset = Int(_u32le(header, cmdOffset + 8))
				if nameOffset >= 12, cmdOffset + nameOffset < header.count {
					let start = cmdOffset + nameOffset
					let limit = min(cmdOffset + cmdsize, header.count)
					var end = start
					while end < limit && header[end] != 0 { end += 1 }
					if end > start, let name = String(bytes: header[start..<end], encoding: .utf8) {
						names.insert(name)
					}
				}
			}
			cmdOffset += cmdsize
		}
		return names
	}

	/// Searches a binary for the given ASCII markers, in 1MB
	/// chunks with overlap so a marker split across a chunk
	/// boundary is still found.
	private static func _binaryMarkersFound(in executableURL: URL, markers: [String]) -> Set<String> {
		guard let handle = try? FileHandle(forReadingFrom: executableURL) else { return [] }
		defer { try? handle.close() }
		let markerData = markers.map { ($0, Data($0.utf8)) }
		var found = Set<String>()
		let chunkSize = 1024 * 1024
		let overlap = 256
		var carry = Data()
		while found.count < markers.count {
			let chunk = handle.readData(ofLength: chunkSize)
			guard !chunk.isEmpty else { break }
			let data = carry + chunk
			for (marker, bytes) in markerData where !found.contains(marker) {
				if data.range(of: bytes) != nil { found.insert(marker) }
			}
			carry = data.suffix(overlap)
		}
		return found
	}

	private static func _u32le(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
		UInt32(bytes[offset])
			| UInt32(bytes[offset + 1]) << 8
			| UInt32(bytes[offset + 2]) << 16
			| UInt32(bytes[offset + 3]) << 24
	}

	private static func _u32(_ bytes: [UInt8], _ offset: Int, bigEndian: Bool) -> UInt32 {
		if bigEndian {
			return UInt32(bytes[offset]) << 24
				| UInt32(bytes[offset + 1]) << 16
				| UInt32(bytes[offset + 2]) << 8
				| UInt32(bytes[offset + 3])
		}
		return _u32le(bytes, offset)
	}
}

// MARK: - Remover

enum LiteStripRemovalError: Error, LocalizedError {
	case pathNotAllowed(String)
	case notRemovable(String)
	case removalFailed(String)

	var errorDescription: String? {
		switch self {
		case .pathNotAllowed(let path):
			"\(path) is outside the allowed Lite-strip shapes."
		case .notRemovable(let path):
			"\(path) was not verified as safe to remove."
		case .removalFailed(let path):
			"Could not remove \(path)."
		}
	}
}

/// Deletes the chosen Lite-strip candidates from the copied .app
/// before re-signing. Every requested path is re-verified against
/// a fresh scan first: anything linked, unparseable, or no longer
/// detected is refused instead of deleted. Throws on the first
/// refusal, so a half-stripped app is never silently signed.
enum LiteStripRemover {
	static func apply(paths: [String], to appDirectory: URL) throws {
		let removable = LiteStripDetector.removableRelativePaths(in: appDirectory)
		for relativePath in paths {
			guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
				throw LiteStripRemovalError.pathNotAllowed(relativePath)
			}
			let components = relativePath.split(separator: "/").map(String.init)
			guard
				!components.contains(".."), !components.contains("."),
				!components.contains("_CodeSignature"),
				_isAllowedShape(components)
			else {
				throw LiteStripRemovalError.pathNotAllowed(relativePath)
			}
			guard removable.contains(relativePath) else {
				throw LiteStripRemovalError.notRemovable(relativePath)
			}
			let url = components.reduce(appDirectory) { $0.appendingPathComponent($1) }
			do {
				try FileManager.default.removeItem(at: url)
			} catch {
				throw LiteStripRemovalError.removalFailed(relativePath)
			}
		}
	}

	/// Only the three shapes the detector ever offers:
	/// `Frameworks/<name>.framework`, `<lang>.lproj`, or a junk
	/// file name at any depth inside the bundle.
	private static func _isAllowedShape(_ components: [String]) -> Bool {
		if components.count == 2,
		   components[0] == "Frameworks",
		   components[1].hasSuffix(".framework") {
			return true
		}
		if components.count == 1, components[0].hasSuffix(".lproj") {
			return true
		}
		if let last = components.last, LiteStripDetector.junkFileNames.contains(last) {
			return true
		}
		return false
	}
}
