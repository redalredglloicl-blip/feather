
//
//  WatermarkDetector.swift
//  Zenith
//
//  Zenith v2.12, item 13 (#40): find watermark overlays /
//  watermark SDKs / watermark-drawing code in an imported .app
//  bundle and offer to remove them before signing.
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * Only LOCAL things can be changed: a Bool key that switches
//    the watermark on (set to false), a watermark text that is
//    stored locally (cleared), or a bundled watermark framework
//    the main executable does NOT link (deleted).
//  * A watermark framework the main executable DOES link cannot
//    be deleted — deleting it breaks the app at launch (dyld:
//    Library not loaded). Linkage is verified by parsing the
//    main executable's Mach-O load commands in pure Swift (FAT +
//    64/32-bit thin). When the header cannot be parsed, linkage
//    is treated as UNKNOWN and the framework is never removed —
//    never guessed.
//  * Watermark code compiled straight into the main executable
//    cannot be removed at all — it is reported as found-in-binary
//    only.
//  * Watermarks added server-side (e.g. burned into downloaded
//    media on the server) are not inside the app at all and cannot
//    be removed from the device.
//

import Foundation

// MARK: - Model

/// One watermark framework found inside the .app bundle.
struct DetectedWatermarkFramework: Identifiable, Equatable {
	var id: String { frameworkName }

	/// Bundle name on disk, e.g. `WatermarkKit.framework`.
	var frameworkName: String
	/// Path inside the .app, e.g. `Frameworks/WatermarkKit.framework`.
	var relativePath: String
	/// True when the main executable links this framework.
	var isLinked: Bool
	/// False when the Mach-O header could not be parsed at all.
	/// A framework with unknown linkage is never removable.
	var linkageKnown: Bool

	/// Only a bundled framework with proven-unlinked status may be
	/// deleted. Everything else is detection-only.
	var isRemovable: Bool { linkageKnown && !isLinked }
}

/// One local config value that may switch the watermark on or
/// carry its text, with the change that would remove it. Nil
/// change means the value is shown for information only.
struct WatermarkFinding: Identifiable, Equatable {
	var id: String { finding.id }

	var finding: AppConfigFinding
	/// The staged change that removes the watermark, or nil when
	/// this value is already off / already empty.
	var proposedChange: AppConfigChange?

	/// True when the watermark is already off for this value, so
	/// there is nothing to change.
	var alreadyOff: Bool { proposedChange == nil }
}

/// The outcome of the watermark scan.
struct WatermarkReport: Equatable {
	var configFindings: [WatermarkFinding]
	var frameworks: [DetectedWatermarkFramework]
	/// True when the literal string "watermark" was found inside
	/// the main executable itself (statically linked code).
	var foundInBinary: Bool
}

// MARK: - Detector

enum WatermarkDetector {
	/// Substrings that mark a key as watermark-related.
	/// Matching is case-insensitive.
	static let keyPatterns = ["watermark"]
	/// Substrings in a file name that mark the whole file as
	/// config worth parsing.
	static let fileNameHints = [
		"config", "settings", "remote", "feature", "flags",
		"defaults", "preferences", "constants", "app",
		"watermark", "export", "editor", "media",
	]

	/// Scans `appDirectory` (a `.app` bundle) for watermarks.
	/// Synchronous — call from a background queue.
	static func detect(appDirectory: URL) -> WatermarkReport {
		let configFindings = _detectConfig(appDirectory: appDirectory)
		let (frameworks, foundInBinary) = _detectFrameworksAndBinary(appDirectory: appDirectory)
		return WatermarkReport(
			configFindings: configFindings,
			frameworks: frameworks,
			foundInBinary: foundInBinary
		)
	}

	// MARK: Config values

	private static func _detectConfig(appDirectory: URL) -> [WatermarkFinding] {
		let found = AppConfigScanner.scan(
			appDirectory: appDirectory,
			keyPatterns: keyPatterns,
			fileNameHints: fileNameHints
		)
		var results: [WatermarkFinding] = []
		for finding in found {
			switch finding.value {
			case .bool(let isOn):
				// A switch that is on gets turned off. A switch
				// that is already off is shown as already-off.
				results.append(WatermarkFinding(
					finding: finding,
					proposedChange: isOn ? AppConfigChange(
						relativePath: finding.relativePath,
						key: finding.key,
						value: .bool(false)
					) : nil
				))
			case .string(let text):
				// A stored watermark text (e.g. "Made with X")
				// gets cleared. An already-empty text is shown
				// as already-off.
				results.append(WatermarkFinding(
					finding: finding,
					proposedChange: text.isEmpty ? nil : AppConfigChange(
						relativePath: finding.relativePath,
						key: finding.key,
						value: .string("")
					)
				))
			case .number:
				// A number alone says nothing about a watermark
				// (opacity? count?) — shown for information only,
				// never changed, so no fake removal is offered.
				results.append(WatermarkFinding(finding: finding, proposedChange: nil))
			}
		}
		return results
	}

	// MARK: Frameworks + binary

	private static func _detectFrameworksAndBinary(
		appDirectory: URL
	) -> ([DetectedWatermarkFramework], Bool) {
		var frameworks: [DetectedWatermarkFramework] = []

		let frameworksDir = appDirectory.appendingPathComponent("Frameworks")
		var frameworkNames: [String] = []
		if let entries = try? FileManager.default.contentsOfDirectory(
			at: frameworksDir,
			includingPropertiesForKeys: [.isDirectoryKey]
		) {
			for url in entries where url.pathExtension.lowercased() == "framework" {
				let name = url.lastPathComponent
				guard name.lowercased().contains("watermark") else { continue }
				frameworkNames.append(name)
			}
		}

		var linkedNames: Set<String>? = nil
		var foundInBinary = false
		if let executableURL = Bundle(url: appDirectory)?.executableURL {
			linkedNames = _linkedInstallNames(in: executableURL)
			foundInBinary = _binaryContainsWatermark(in: executableURL)
		}
		let linkageKnown = linkedNames != nil

		for name in frameworkNames {
			let baseName = name.replacingOccurrences(of: ".framework", with: "")
			let isLinked = linkedNames?.contains {
				$0.contains(name) || $0.hasSuffix("/" + baseName)
			} ?? false
			frameworks.append(DetectedWatermarkFramework(
				frameworkName: name,
				relativePath: "Frameworks/" + name,
				isLinked: isLinked,
				linkageKnown: linkageKnown
			))
		}

		frameworks.sort { $0.frameworkName < $1.frameworkName }
		return (frameworks, foundInBinary)
	}

	/// Relative paths of the frameworks that may be deleted, as
	/// verified by a fresh scan. The remover uses this instead of
	/// trusting a stale selection.
	static func removableRelativePaths(in appDirectory: URL) -> Set<String> {
		var removable: Set<String> = []
		let frameworksDir = appDirectory.appendingPathComponent("Frameworks")
		guard
			let entries = try? FileManager.default.contentsOfDirectory(
				at: frameworksDir,
				includingPropertiesForKeys: [.isDirectoryKey]
			),
			let executableURL = Bundle(url: appDirectory)?.executableURL,
			let linkedNames = _linkedInstallNames(in: executableURL)
		else {
			return removable
		}
		for url in entries where url.pathExtension.lowercased() == "framework" {
			let name = url.lastPathComponent
			guard name.lowercased().contains("watermark") else { continue }
			let baseName = name.replacingOccurrences(of: ".framework", with: "")
			let isLinked = linkedNames.contains {
				$0.contains(name) || $0.hasSuffix("/" + baseName)
			}
			if !isLinked {
				removable.insert("Frameworks/" + name)
			}
		}
		return removable
	}

	// MARK: - Mach-O linkage parsing

	/// Install names from the main executable's LC_LOAD_*_DYLIB
	/// commands. Nil when the file cannot be read or its header
	/// cannot be parsed — callers must treat that as "unknown",
	/// never as "unlinked".
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

	/// Searches the main executable for the literal strings
	/// "watermark" / "Watermark" / "WATERMARK", in 1MB chunks
	/// with overlap so a marker split across a chunk boundary is
	/// still found. A hit only proves watermark code is compiled
	/// into the app — it is detection-only, never removal.
	private static func _binaryContainsWatermark(in executableURL: URL) -> Bool {
		guard let handle = try? FileHandle(forReadingFrom: executableURL) else { return false }
		defer { try? handle.close() }
		let markers = ["watermark", "Watermark", "WATERMARK"].map { Data($0.utf8) }
		let chunkSize = 1024 * 1024
		let overlap = 256
		var carry = Data()
		while true {
			let chunk = handle.readData(ofLength: chunkSize)
			guard !chunk.isEmpty else { break }
			let data = carry + chunk
			for marker in markers {
				if data.range(of: marker) != nil { return true }
			}
			carry = data.suffix(overlap)
		}
		return false
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

enum WatermarkRemovalError: Error, LocalizedError {
	case pathNotAllowed(String)
	case notRemovable(String)
	case removalFailed(String)

	var errorDescription: String? {
		switch self {
		case .pathNotAllowed(let path):
			"\(path) is outside the app bundle."
		case .notRemovable(let path):
			"\(path) is linked by the app or was not verified as safe to remove."
		case .removalFailed(let path):
			"Could not remove \(path)."
		}
	}
}

/// Deletes the chosen watermark frameworks from the copied .app
/// before re-signing. Every requested path is re-verified against
/// a fresh scan first: anything linked, unparseable, or no longer
/// detected is refused instead of deleted. Throws on the first
/// refusal, so a half-stripped app is never silently signed.
/// (The config changes in Options.removeWatermarkChanges are
/// applied separately by AppConfigApplier.)
enum WatermarkRemover {
	static func apply(frameworks: [String], to appDirectory: URL) throws {
		let removable = WatermarkDetector.removableRelativePaths(in: appDirectory)
		for relativePath in frameworks {
			guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
				throw WatermarkRemovalError.pathNotAllowed(relativePath)
			}
			let components = relativePath.split(separator: "/").map(String.init)
			guard
				!components.contains(".."), !components.contains("."),
				components.count == 2,
				components[0] == "Frameworks",
				components[1].hasSuffix(".framework")
			else {
				throw WatermarkRemovalError.pathNotAllowed(relativePath)
			}
			guard removable.contains(relativePath) else {
				throw WatermarkRemovalError.notRemovable(relativePath)
			}
			let url = appDirectory
				.appendingPathComponent(components[0])
				.appendingPathComponent(components[1])
			do {
				try FileManager.default.removeItem(at: url)
			} catch {
				throw WatermarkRemovalError.removalFailed(relativePath)
			}
		}
	}
}
