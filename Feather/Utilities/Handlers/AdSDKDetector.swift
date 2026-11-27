//
//  AdSDKDetector.swift
//  Zenith
//
//  Zenith v2.12, item 8 (#23): detect ad SDKs inside an imported
//  .app bundle and strip the ones that can be removed safely.
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * Only a bundled .framework that the main executable does NOT
//    link can be deleted. Deleting a linked framework breaks the
//    app at launch (dyld: Library not loaded), and this toolchain
//    has no Mach-O load-command editor to unlink it, so linked
//    frameworks are reported and left alone.
//  * An SDK compiled straight into the main executable (no
//    .framework on disk) cannot be removed at all — it is reported
//    as found-in-binary.
//  * Server-served ads are not inside the app at all and cannot be
//    removed from the device.
//
//  Linkage is verified by parsing the main executable's Mach-O
//  load commands in pure Swift (FAT + 64/32-bit thin), collecting
//  LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB /
//  LC_LOAD_UPWARD_DYLIB install names. When the header cannot be
//  parsed, linkage is treated as UNKNOWN and the framework is
//  never removed — never guessed.
//

import Foundation

// MARK: - Model

/// One ad SDK found inside the .app bundle.
struct DetectedAdSDK: Identifiable, Equatable {
	var id: String { relativePath ?? frameworkName }

	/// Bundle name on disk, e.g. `GoogleMobileAds.framework`.
	var frameworkName: String
	/// Human-readable name, e.g. `Google AdMob`.
	var displayName: String
	/// Path inside the .app, e.g. `Frameworks/GoogleMobileAds.framework`.
	/// Nil when the SDK is only found inside the main executable.
	var relativePath: String?
	/// True when the SDK's code was found inside the main executable
	/// itself (statically linked), even if a .framework also exists.
	var foundInBinary: Bool
	/// True when the main executable links this framework.
	var isLinked: Bool
	/// False when the Mach-O header could not be parsed at all.
	/// A framework with unknown linkage is never removable.
	var linkageKnown: Bool

	/// Only a bundled framework with proven-unlinked status may be
	/// deleted. Everything else is detection-only.
	var isRemovable: Bool { relativePath != nil && linkageKnown && !isLinked }
}

/// The outcome of the ad SDK scan.
struct AdSDKReport: Equatable {
	var sdks: [DetectedAdSDK]
	/// False when the main executable could not be found or its
	/// Mach-O header could not be parsed, so no framework could
	/// be proven unlinked.
	var linkageKnown: Bool
}

// MARK: - Known SDKs

struct KnownAdSDK {
	var frameworkName: String
	var displayName: String
	/// Distinctive strings found in the main executable when the
	/// SDK is compiled in statically.
	var binaryMarkers: [String]
}

// MARK: - Detector

enum AdSDKDetector {
	static let knownSDKs: [KnownAdSDK] = [
		KnownAdSDK(frameworkName: "GoogleMobileAds.framework", displayName: "Google AdMob", binaryMarkers: ["GADMobileAds", "GADRequest"]),
		KnownAdSDK(frameworkName: "AppLovinSDK.framework", displayName: "AppLovin MAX", binaryMarkers: ["AppLovinSDK", "ALSdkSettings"]),
		KnownAdSDK(frameworkName: "UnityAds.framework", displayName: "Unity Ads", binaryMarkers: ["UnityAds"]),
		KnownAdSDK(frameworkName: "IronSource.framework", displayName: "ironSource", binaryMarkers: ["IronSource", "ISIntegrationHelper"]),
		KnownAdSDK(frameworkName: "FBAudienceNetwork.framework", displayName: "Meta Audience Network", binaryMarkers: ["FBAudienceNetwork", "FBAdView"]),
		KnownAdSDK(frameworkName: "VungleSDK.framework", displayName: "Vungle", binaryMarkers: ["VungleSDK"]),
		KnownAdSDK(frameworkName: "VungleAdsSDK.framework", displayName: "Vungle Ads", binaryMarkers: ["VungleAds"]),
		KnownAdSDK(frameworkName: "ChartboostSDK.framework", displayName: "Chartboost", binaryMarkers: ["Chartboost"]),
		KnownAdSDK(frameworkName: "InMobiSDK.framework", displayName: "InMobi", binaryMarkers: ["InMobiSDK"]),
		KnownAdSDK(frameworkName: "StartAppSDK.framework", displayName: "StartApp", binaryMarkers: ["StartAppSDK", "STAStartAppSDK"]),
		KnownAdSDK(frameworkName: "Appodeal.framework", displayName: "Appodeal", binaryMarkers: ["Appodeal"]),
		KnownAdSDK(frameworkName: "MintegralAdSDK.framework", displayName: "Mintegral", binaryMarkers: ["Mintegral", "MTGSDK"]),
		KnownAdSDK(frameworkName: "BUAdSDK.framework", displayName: "Pangle", binaryMarkers: ["BUAdSDK"]),
		KnownAdSDK(frameworkName: "AdColony.framework", displayName: "AdColony", binaryMarkers: ["AdColony"]),
		KnownAdSDK(frameworkName: "Tapjoy.framework", displayName: "Tapjoy", binaryMarkers: ["Tapjoy"]),
		KnownAdSDK(frameworkName: "CAS.framework", displayName: "Clever Ads Solutions", binaryMarkers: ["CleverAdsSolutions"]),
		KnownAdSDK(frameworkName: "DTBiOSSDK.framework", displayName: "Amazon Publisher Services", binaryMarkers: ["DTBiOSSDK"]),
		KnownAdSDK(frameworkName: "YandexMobileAds.framework", displayName: "Yandex Ads", binaryMarkers: ["YandexMobileAds"]),
		KnownAdSDK(frameworkName: "Fyber.framework", displayName: "Fyber", binaryMarkers: ["Fyber"]),
	]

	/// Scans `appDirectory` (a `.app` bundle) for ad SDKs.
	/// Synchronous — call from a background queue.
	static func detect(appDirectory: URL) -> AdSDKReport {
		var found: [String: DetectedAdSDK] = [:]

		// 1. Bundled frameworks on disk.
		let frameworksDir = appDirectory.appendingPathComponent("Frameworks")
		if let entries = try? FileManager.default.contentsOfDirectory(
			at: frameworksDir,
			includingPropertiesForKeys: [.isDirectoryKey]
		) {
			for url in entries where url.pathExtension.lowercased() == "framework" {
				let name = url.lastPathComponent
				guard let known = knownSDKs.first(where: {
					$0.frameworkName.lowercased() == name.lowercased()
				}) else { continue }
				found[known.frameworkName.lowercased()] = DetectedAdSDK(
					frameworkName: known.frameworkName,
					displayName: known.displayName,
					relativePath: "Frameworks/" + name,
					foundInBinary: false,
					isLinked: false,
					linkageKnown: false
				)
			}
		}

		// 2. Main executable: linkage + statically linked SDKs.
		var linkedNames: Set<String>? = nil
		var foundMarkers: Set<String> = []
		if let executableURL = Bundle(url: appDirectory)?.executableURL {
			linkedNames = _linkedInstallNames(in: executableURL)
			foundMarkers = _binaryMarkersFound(
				in: executableURL,
				markers: knownSDKs.flatMap(\.binaryMarkers)
			)
		}
		let linkageKnown = linkedNames != nil

		for known in knownSDKs {
			let key = known.frameworkName.lowercased()
			let markerHit = known.binaryMarkers.contains { foundMarkers.contains($0) }
			if var existing = found[key] {
				existing.foundInBinary = markerHit
				existing.linkageKnown = linkageKnown
				if let linked = linkedNames {
					let baseName = known.frameworkName.replacingOccurrences(of: ".framework", with: "")
					existing.isLinked = linked.contains {
						$0.contains(known.frameworkName) || $0.hasSuffix("/" + baseName)
					}
				}
				found[key] = existing
			} else if markerHit {
				found[key] = DetectedAdSDK(
					frameworkName: known.frameworkName,
					displayName: known.displayName,
					relativePath: nil,
					foundInBinary: true,
					isLinked: false,
					linkageKnown: true
				)
			}
		}

		var sdks = Array(found.values)
		sdks.sort { $0.displayName < $1.displayName }
		return AdSDKReport(sdks: sdks, linkageKnown: linkageKnown)
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
			guard let known = knownSDKs.first(where: {
				$0.frameworkName.lowercased() == name.lowercased()
			}) else { continue }
			let baseName = known.frameworkName.replacingOccurrences(of: ".framework", with: "")
			let isLinked = linkedNames.contains {
				$0.contains(known.frameworkName) || $0.hasSuffix("/" + baseName)
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

	/// Searches the main executable for the given ASCII markers,
	/// in 1MB chunks with overlap so a marker split across a chunk
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

enum AdSDKRemovalError: Error, LocalizedError {
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

/// Deletes the chosen ad SDK frameworks from the copied .app
/// before re-signing. Every requested path is re-verified against
/// a fresh scan first: anything linked, unparseable, or no longer
/// detected is refused instead of deleted. Throws on the first
/// refusal, so a half-stripped app is never silently signed.
enum AdSDKRemover {
	static func apply(frameworks: [String], to appDirectory: URL) throws {
		let removable = AdSDKDetector.removableRelativePaths(in: appDirectory)
		for relativePath in frameworks {
			guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
				throw AdSDKRemovalError.pathNotAllowed(relativePath)
			}
			let components = relativePath.split(separator: "/").map(String.init)
			guard
				!components.contains(".."), !components.contains("."),
				components.count == 2,
				components[0] == "Frameworks",
				components[1].hasSuffix(".framework")
			else {
				throw AdSDKRemovalError.pathNotAllowed(relativePath)
			}
			guard removable.contains(relativePath) else {
				throw AdSDKRemovalError.notRemovable(relativePath)
			}
			let url = appDirectory
				.appendingPathComponent(components[0])
				.appendingPathComponent(components[1])
			do {
				try FileManager.default.removeItem(at: url)
			} catch {
				throw AdSDKRemovalError.removalFailed(relativePath)
			}
		}
	}
}
