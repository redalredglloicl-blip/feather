
//
//  LocationSpoofDetector.swift
//  Zenith
//
//  Zenith v2.12, item 19 (#60): change the location an app sees.
//
//  The screen scans the imported .app for proof that it reads the
//  device location (a CoreLocation link in the main executable's
//  load commands, or NSLocation*UsageDescription keys in its
//  Info.plist) and offers a city / custom-coordinate picker.
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * The override is a small JSON file (`ZenithLocationSpoof.json`)
//    written into the copied .app by LocationSpoofWriter at signing
//    time, so it is covered by the fresh signature. The file alone
//    does NOTHING — a location-spoof tweak (a .dylib that answers
//    CoreLocation with the chosen coordinate) must read it at
//    runtime. Zenith ships no such tweak: the user brings their own
//    .dylib, added through the existing injection path
//    (TweakHandler / Zsign.injectDyLib, same as any tweak). If no
//    tweak is added, the view says so plainly instead of pretending
//    the location changed.
//  * Only apps that read location locally through standard
//    CoreLocation can be spoofed. Apps that verify location on
//    their server cannot be spoofed from the device.
//  * An app with no location usage at all is not offered the
//    toggle — spoofing it would change nothing.
//

import Foundation

// MARK: - Model

/// One city the user can pretend to be in.
struct LocationSpoofPreset: Identifiable, Equatable {
	var id: String { englishName }

	/// English name, also the stable id and the label written
	/// into ZenithLocationSpoof.json for a tweak to read.
	var englishName: String
	var latitude: Double
	var longitude: Double

	/// The row shows the localized city name.
	var localizedName: String {
		.localized("City \(englishName)")
	}
}

/// The user's chosen override, staged in
/// Options.locationSpoof for this signing run. Nil means the
/// feature is off.
struct LocationSpoofSelection: Codable, Equatable {
	var latitude: Double
	var longitude: Double
	/// The preset's English name when the choice came from the
	/// preset list, nil for a hand-typed coordinate.
	var presetID: String?

	var label: String {
		presetID ?? "custom"
	}

	var displayName: String {
		if let presetID {
			return .localized("City \(presetID)")
		}
		return .localized("Custom Location")
	}

	var coordinateText: String {
		String(format: "%.4f, %.4f", latitude, longitude)
	}
}

/// The outcome of the location-usage scan.
struct LocationSpoofReport: Equatable {
	/// True when the app links CoreLocation or declares a
	/// location usage description.
	var usesCoreLocation: Bool
	/// False when the executable header could not be parsed —
	/// linkage is then unknown, never "not linked".
	var linkageKnown: Bool
	/// True when a CoreLocation install name was found in the
	/// main executable's load commands.
	var isLinked: Bool
	/// NSLocation*UsageDescription keys found in Info.plist.
	var usageKeys: [String]
}

// MARK: - Detector

enum LocationSpoofDetector {
	/// Preset cities, in the order the picker shows them.
	static let presets: [LocationSpoofPreset] = [
		LocationSpoofPreset(englishName: "Baghdad", latitude: 33.3152, longitude: 44.3661),
		LocationSpoofPreset(englishName: "Dubai", latitude: 25.2048, longitude: 55.2708),
		LocationSpoofPreset(englishName: "Riyadh", latitude: 24.7136, longitude: 46.6753),
		LocationSpoofPreset(englishName: "Cairo", latitude: 30.0444, longitude: 31.2357),
		LocationSpoofPreset(englishName: "Istanbul", latitude: 41.0082, longitude: 28.9784),
		LocationSpoofPreset(englishName: "London", latitude: 51.5074, longitude: -0.1278),
		LocationSpoofPreset(englishName: "New York", latitude: 40.7128, longitude: -74.0060),
		LocationSpoofPreset(englishName: "Paris", latitude: 48.8566, longitude: 2.3522),
		LocationSpoofPreset(englishName: "Tokyo", latitude: 35.6762, longitude: 139.6503),
	]

	/// The file the override is written to inside the .app.
	static let configFileName = "ZenithLocationSpoof.json"

	/// Valid latitude / longitude ranges, for the custom fields.
	static func isValid(latitude: Double, longitude: Double) -> Bool {
		latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
	}

	/// Scans `appDirectory` (a `.app` bundle) for location usage.
	/// Synchronous — call from a background queue.
	static func detect(appDirectory: URL) -> LocationSpoofReport {
		var usageKeys: [String] = []
		let infoURL = appDirectory.appendingPathComponent("Info.plist")
		if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] {
			usageKeys = dict.keys
				.compactMap { $0 as? String }
				.filter { $0.hasPrefix("NSLocation") }
				.sorted()
		}

		var isLinked = false
		var linkageKnown = false
		if let executableURL = Bundle(url: appDirectory)?.executableURL,
		   let linkedNames = _linkedInstallNames(in: executableURL) {
			linkageKnown = true
			isLinked = linkedNames.contains { $0.contains("CoreLocation") }
		}

		return LocationSpoofReport(
			usesCoreLocation: isLinked || !usageKeys.isEmpty,
			linkageKnown: linkageKnown,
			isLinked: isLinked,
			usageKeys: usageKeys
		)
	}

	// MARK: - Mach-O linkage parsing

	/// Install names from the main executable's LC_LOAD_*_DYLIB
	/// commands. Nil when the file cannot be read or its header
	/// cannot be parsed — callers must treat that as "unknown",
	/// never as "unlinked". Same technique as AdSDKDetector.
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

// MARK: - Writer

enum LocationSpoofWriterError: Error, LocalizedError {
	case writeFailed(String)

	var errorDescription: String? {
		switch self {
		case .writeFailed(let path):
			"Could not save \(path)."
		}
	}
}

/// Writes the chosen override into the copied .app before
/// re-signing, as `ZenithLocationSpoof.json` at the bundle root:
/// `{"latitude": ..., "longitude": ..., "label": ...}`. A
/// location-spoof tweak reads this file at runtime and answers
/// CoreLocation with the coordinate. With a nil selection any
/// stale file is removed, so an earlier choice never leaks into
/// a later signing. Throws when the file cannot be written, so a
/// signing run never pretends the override was saved when it
/// was not.
enum LocationSpoofWriter {
	static func apply(selection: LocationSpoofSelection?, to appDirectory: URL) throws {
		let url = appDirectory.appendingPathComponent(LocationSpoofDetector.configFileName)
		guard let selection else {
			if FileManager.default.fileExists(atPath: url.path) {
				try FileManager.default.removeItem(at: url)
			}
			return
		}
		let object: [String: Any] = [
			"latitude": selection.latitude,
			"longitude": selection.longitude,
			"label": selection.label,
		]
		do {
			let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
			try data.write(to: url, options: .atomic)
		} catch {
			throw LocationSpoofWriterError.writeFailed(LocationSpoofDetector.configFileName)
		}
	}
}
