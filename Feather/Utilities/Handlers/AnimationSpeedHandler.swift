//
//  AnimationSpeedHandler.swift
//  Zenith
//
//  Zenith v2.12, item 18 (#46): speed up an app's animations at
//  signing time by shortening animation-duration values in its
//  bundled config files.
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * Only durations stored as NUMBERS in bundled .plist / .json
//    config files can be shortened. If no such key exists, the UI
//    says so instead of showing a fake toggle.
//  * Animations hardcoded in the binary (durations baked into the
//    compiled code, or driven by the system) cannot be patched
//    from the device — there is no binary patcher here.
//  * Only keys that already exist are changed — no keys are
//    invented, because an invented key does nothing. A missing
//    key at apply time is refused instead of created.
//  * Durations nested inside arrays are not scanned (dictionaries
//    only), and only values between 0 and 30 seconds are offered:
//    a number outside that range is almost certainly not an
//    animation duration.
//  * Halving a duration only asks the app to animate faster; some
//    apps ignore the value, or tie logic to the timing, so a
//    faster animation is not promised for every key.
//
//  SIGNING HOOK (coordinator, in SigningHandler.modify(), after
//  the modFileEdits block, before re-signing):
//
//    if !_options.animationDurationChanges.isEmpty {
//        try AnimationSpeedApplier.apply(changes: _options.animationDurationChanges, to: movedAppPath)
//    }
//
//  OPTIONS (coordinator, OptionsManager.swift — field does not
//  exist yet, same as items 8/9):
//
//    var animationDurationChanges: [AnimationDurationChange]
//    // default: animationDurationChanges: []
//

import Foundation

// MARK: - Model

/// One animation-duration value found in a bundled config file.
struct AnimationDurationKey: Identifiable, Equatable {
	var id: String { relativePath + "#" + keyPath }

	/// Path inside the .app, e.g. `Config/Animations.plist`.
	var relativePath: String
	/// Dotted key path inside the file, e.g. `Fade.Duration`.
	var keyPath: String
	/// `plist` or `json`.
	var fileKind: String
	/// The duration as shipped, in seconds.
	var originalValue: Double
	/// The offered shortened duration: half the original.
	var newValue: Double { (originalValue * 0.5 * 1000).rounded() / 1000 }
}

/// One staged duration shortening, applied at signing time.
struct AnimationDurationChange: Codable, Equatable, Identifiable {
	var id: String { relativePath + "#" + keyPath }

	var relativePath: String
	var keyPath: String
	/// The value the key had when it was scanned.
	var originalValue: Double
	/// The value to write (half the original).
	var newValue: Double
}

/// The outcome of the animation-duration scan.
struct AnimationSpeedReport: Equatable {
	var keys: [AnimationDurationKey]
	/// How many bundled .plist files were parsed.
	var scannedPlistCount: Int
	/// How many bundled .json files were parsed.
	var scannedJSONCount: Int
}

// MARK: - Detector

enum AnimationSpeedDetector {
	/// Substrings that mark a key as an animation duration.
	/// Matching is case-insensitive.
	static let keyPatterns = [
		"duration",
		"animationspeed",
	]
	/// Safety cap so a huge bundle cannot stall the signing screen.
	static let maxScannedEntries = 20000
	/// Safety cap on how many config files are parsed.
	static let maxFilesParsed = 200
	/// Deepest nesting followed inside a config file.
	static let maxDepth = 5
	/// Only durations in this range (seconds) are offered.
	static let maxDurationSeconds = 30.0

	/// Scans `appDirectory` (a `.app` bundle) for numeric
	/// animation-duration keys in bundled .plist / .json files.
	/// Synchronous — call from a background queue.
	static func detect(appDirectory: URL) -> AnimationSpeedReport {
		var keys: [AnimationDurationKey] = []
		var seen = Set<String>()
		var scannedPlistCount = 0
		var scannedJSONCount = 0

		func add(_ key: AnimationDurationKey) {
			guard seen.insert(key.id).inserted else { return }
			keys.append(key)
		}

		let appPath = appDirectory.path
		guard let enumerator = FileManager.default.enumerator(
			at: appDirectory,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		) else {
			return AnimationSpeedReport(keys: [], scannedPlistCount: 0, scannedJSONCount: 0)
		}

		var scanned = 0
		var parsed = 0
		for case let url as URL in enumerator {
			scanned += 1
			if scanned > maxScannedEntries { break }

			let relativePath = url.path.replacingOccurrences(of: appPath + "/", with: "")
			let firstComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
			if ["_CodeSignature", "Frameworks", "PlugIns", "Watch"].contains(firstComponent) {
				continue
			}
			if relativePath.contains(".lproj/") { continue }

			let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
			guard values?.isRegularFile == true else { continue }

			let ext = url.pathExtension.lowercased()
			guard ext == "plist" || ext == "json" else { continue }
			guard parsed < maxFilesParsed else { break }
			parsed += 1

			if ext == "plist" {
				scannedPlistCount += 1
				guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { continue }
				_walk(dict, path: "", relativePath: relativePath, fileKind: "plist", depth: 0, add: add)
			} else {
				scannedJSONCount += 1
				guard
					let data = try? Data(contentsOf: url),
					let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
				else { continue }
				_walk(dict, path: "", relativePath: relativePath, fileKind: "json", depth: 0, add: add)
			}
		}

		keys.sort {
			if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
			return $0.keyPath < $1.keyPath
		}
		return AnimationSpeedReport(
			keys: keys,
			scannedPlistCount: scannedPlistCount,
			scannedJSONCount: scannedJSONCount
		)
	}

	// MARK: - Helpers

	/// Recursively walks nested dictionaries (arrays are skipped:
	/// durations inside arrays are not offered). Only numeric,
	/// non-boolean values in the valid range are collected.
	private static func _walk(
		_ dict: [String: Any],
		path: String,
		relativePath: String,
		fileKind: String,
		depth: Int,
		add: (AnimationDurationKey) -> Void
	) {
		guard depth <= maxDepth else { return }
		for (key, value) in dict {
			let keyPath = path.isEmpty ? key : path + "." + key
			if let nested = value as? [String: Any] {
				_walk(nested, path: keyPath, relativePath: relativePath, fileKind: fileKind, depth: depth + 1, add: add)
			} else if _matchesPattern(key), let seconds = _durationValue(value) {
				add(AnimationDurationKey(
					relativePath: relativePath,
					keyPath: keyPath,
					fileKind: fileKind,
					originalValue: seconds
				))
			}
		}
	}

	private static func _matchesPattern(_ text: String) -> Bool {
		let lower = text.lowercased()
		return keyPatterns.contains { lower.contains($0) }
	}

	/// Returns the numeric value, or nil when it is not a real
	/// number, is a boolean, or is outside the animation range.
	/// A plain `as? Double` is not enough: booleans also bridge
	/// to numbers, so the CFBoolean type check keeps `true` /
	/// `false` from being offered as durations.
	private static func _durationValue(_ value: Any) -> Double? {
		guard let number = value as? NSNumber else { return nil }
		guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
		let seconds = number.doubleValue
		guard seconds.isFinite, seconds > 0, seconds <= maxDurationSeconds else { return nil }
		return seconds
	}
}

// MARK: - Errors

enum AnimationSpeedApplyError: Error, LocalizedError {
	case pathNotAllowed(String)
	case fileNotFound(String)
	case keyNotFound(String)
	case notANumber(String)
	case writeFailed(String)

	var errorDescription: String? {
		switch self {
		case .pathNotAllowed(let path):
			"\(path) is outside the app bundle."
		case .fileNotFound(let path):
			"\(path) was not found."
		case .keyNotFound(let key):
			"\(key) no longer exists in the app."
		case .notANumber(let key):
			"\(key) is no longer a number."
		case .writeFailed(let path):
			"Could not save \(path)."
		}
	}
}

// MARK: - Applier

/// Shortens the chosen animation durations inside the copied .app
/// before re-signing. Only keys that already exist are set — a
/// missing key is refused instead of invented. Throws on the
/// first change that cannot be applied, so a half-applied set is
/// never silently signed.
enum AnimationSpeedApplier {
	static func apply(changes: [AnimationDurationChange], to appDirectory: URL) throws {
		for change in changes {
			let url = try _resolvedURL(for: change.relativePath, in: appDirectory)
			guard FileManager.default.fileExists(atPath: url.path) else {
				throw AnimationSpeedApplyError.fileNotFound(change.relativePath)
			}
			if url.pathExtension.lowercased() == "json" {
				try _applyJSON(change, at: url)
			} else {
				try _applyPlist(change, at: url)
			}
		}
	}

	private static func _applyPlist(_ change: AnimationDurationChange, at url: URL) throws {
		guard let dict = NSMutableDictionary(contentsOf: url) else {
			throw AnimationSpeedApplyError.writeFailed(change.relativePath)
		}
		guard _setNested(dict, keyPath: change.keyPath, value: change.newValue, id: change.id) else {
			throw AnimationSpeedApplyError.keyNotFound(change.id)
		}
		guard dict.write(to: url, atomically: true) else {
			throw AnimationSpeedApplyError.writeFailed(change.relativePath)
		}
	}

	private static func _applyJSON(_ change: AnimationDurationChange, at url: URL) throws {
		do {
			let data = try Data(contentsOf: url)
			guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				throw AnimationSpeedApplyError.writeFailed(change.relativePath)
			}
			guard _setNestedJSON(&dict, keyPath: change.keyPath, value: change.newValue) else {
				throw AnimationSpeedApplyError.keyNotFound(change.id)
			}
			let out = try JSONSerialization.data(
				withJSONObject: dict,
				options: [.prettyPrinted, .sortedKeys]
			)
			try out.write(to: url, options: .atomic)
		} catch let error as AnimationSpeedApplyError {
			throw error
		} catch {
			throw AnimationSpeedApplyError.writeFailed(change.relativePath)
		}
	}

	/// Sets a dotted key path inside a mutable plist dictionary.
	/// Returns false when any component is missing, is not a
	/// dictionary, or the final value is not a number. Nested
	/// dictionaries are copied to mutable ones on the way down,
	/// because a plist read is only guaranteed mutable at the
	/// top level.
	private static func _setNested(
		_ dict: NSMutableDictionary,
		keyPath: String,
		value: Double,
		id: String
	) -> Bool {
		let components = keyPath.split(separator: ".").map(String.init)
		guard !components.isEmpty else { return false }
		var current: NSMutableDictionary = dict
		for component in components.dropLast() {
			if let next = current[component] as? NSMutableDictionary {
				current = next
			} else if let next = current[component] as? NSDictionary {
				let copy = next.mutableCopy() as! NSMutableDictionary
				current[component] = copy
				current = copy
			} else {
				return false
			}
		}
		guard let last = components.last,
		      let number = current[last] as? NSNumber,
		      CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID()
		else { return false }
		current[last] = NSNumber(value: value)
		return true
	}

	/// Sets a dotted key path inside a JSON dictionary (value
	/// semantics — mutates the caller's copy). Returns false when
	/// any component is missing, is not a dictionary, or the
	/// final value is not a number.
	private static func _setNestedJSON(
		_ dict: inout [String: Any],
		keyPath: String,
		value: Double
	) -> Bool {
		let components = keyPath.split(separator: ".").map(String.init)
		guard let first = components.first else { return false }
		if components.count == 1 {
			guard let number = dict[first] as? NSNumber,
			      CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID()
			else { return false }
			dict[first] = value
			return true
		}
		guard var nested = dict[first] as? [String: Any] else { return false }
		let ok = _setNestedJSON(&nested, keyPath: components.dropFirst().joined(separator: "."), value: value)
		guard ok else { return false }
		dict[first] = nested
		return true
	}

	/// Resolves a staged relative path inside the bundle, refusing
	/// anything that would escape it (`..`, absolute paths).
	private static func _resolvedURL(for relativePath: String, in appDirectory: URL) throws -> URL {
		guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
			throw AnimationSpeedApplyError.pathNotAllowed(relativePath)
		}
		let components = relativePath.split(separator: "/").map(String.init)
		guard !components.contains(".."), !components.contains(".") else {
			throw AnimationSpeedApplyError.pathNotAllowed(relativePath)
		}
		let url = components.reduce(appDirectory) { $0.appendingPathComponent($1) }
		guard url.path.hasPrefix(appDirectory.path + "/") else {
			throw AnimationSpeedApplyError.pathNotAllowed(relativePath)
		}
		return url
	}
}
