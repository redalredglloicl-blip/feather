
//
//  AppModConfig.swift
//  Zenith
//
//  Zenith v2.12, items 13-16 (#40-#43): shared plumbing for the
//  app-modding tools that work by changing local config values
//  (remove watermark, remove export limits, remove subscription
//  screen, stop forced in-app updates).
//
//  HONEST LIMITS — the UI of every tool states these plainly:
//  * Only values that already exist in a bundled .plist / .json
//    file (or the app's Settings.bundle) can be changed. No keys
//    are invented, because an invented key does nothing.
//  * Only TOP-LEVEL keys are read and written. A value buried in
//    a nested dictionary is not offered, instead of being guessed
//    at.
//  * Only Bool, number, and String values are handled. Arrays,
//    dictionaries, and binary blobs are skipped.
//  * A staged change is applied to the copied .app by
//    SigningHandler before re-signing, so it is covered by the
//    fresh signature. If the key is gone by signing time, the
//    whole signing run fails loudly instead of signing a
//    half-patched app.
//  * Server-side enforcement cannot be changed from the device,
//    and none of these tools pretend otherwise.
//

import Foundation

// MARK: - Model

/// Where a config value was found.
enum AppConfigSource: String, Codable {
	case infoPlist
	case plistFile
	case jsonFile
	case settingsBundle
}

/// A local config value that can be read and written back.
enum AppConfigValue: Codable, Equatable {
	case bool(Bool)
	case number(Double)
	case string(String)

	/// Short human-readable form for the UI row, e.g. `true`,
	/// `999999`, `720p`.
	var display: String {
		switch self {
		case .bool(let value):
			value ? "true" : "false"
		case .number(let value):
			if value == value.rounded(), abs(value) < 9_000_000_000_000_000 {
				return String(Int(value))
			}
			return String(value)
		case .string(let value):
			value
		}
	}

	// MARK: Codable ({"kind": "...", "value": ...})

	private enum Kind: String, Codable {
		case bool
		case number
		case string
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case value
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		switch try container.decode(Kind.self, forKey: .kind) {
		case .bool:
			self = .bool(try container.decode(Bool.self, forKey: .value))
		case .number:
			self = .number(try container.decode(Double.self, forKey: .value))
		case .string:
			self = .string(try container.decode(String.self, forKey: .value))
		}
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .bool(let value):
			try container.encode(Kind.bool, forKey: .kind)
			try container.encode(value, forKey: .value)
		case .number(let value):
			try container.encode(Kind.number, forKey: .kind)
			try container.encode(value, forKey: .value)
		case .string(let value):
			try container.encode(Kind.string, forKey: .kind)
			try container.encode(value, forKey: .value)
		}
	}
}

/// One local config value found inside the .app bundle.
struct AppConfigFinding: Identifiable, Equatable {
	var id: String { relativePath + "#" + key }

	/// Path inside the .app, e.g. `Config.plist`.
	var relativePath: String
	/// The plist / JSON key.
	var key: String
	var value: AppConfigValue
	var source: AppConfigSource
}

/// One staged config change, applied at signing time.
struct AppConfigChange: Codable, Equatable, Identifiable {
	var id: String { relativePath + "#" + key }

	var relativePath: String
	var key: String
	var value: AppConfigValue
}

// MARK: - Scanner

enum AppConfigScanner {
	/// Safety cap so a huge bundle cannot stall the signing screen.
	static let maxScannedEntries = 20000
	/// Safety cap on how many .plist / .json files are parsed.
	static let maxFilesParsed = 200

	/// Scans `appDirectory` (a `.app` bundle) for top-level keys
	/// whose name contains any of `keyPatterns`
	/// (case-insensitive) in the bundle's Info.plist, its
	/// Settings.bundle, and every bundled .plist / .json file
	/// whose name contains one of `fileNameHints`.
	/// Synchronous — call from a background queue.
	static func scan(
		appDirectory: URL,
		keyPatterns: [String],
		fileNameHints: [String]
	) -> [AppConfigFinding] {
		var findings: [AppConfigFinding] = []
		var seen = Set<String>()

		func add(_ finding: AppConfigFinding) {
			guard seen.insert(finding.id).inserted else { return }
			findings.append(finding)
		}

		func matches(_ key: String) -> Bool {
			let lower = key.lowercased()
			return keyPatterns.contains { lower.contains($0) }
		}

		// 1. The bundle's own Info.plist.
		let infoURL = appDirectory.appendingPathComponent("Info.plist")
		if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] {
			for (key, rawValue) in dict {
				guard matches(key), let value = _configValue(rawValue) else { continue }
				add(AppConfigFinding(
					relativePath: "Info.plist",
					key: key,
					value: value,
					source: .infoPlist
				))
			}
		}

		// 2. The app's Settings.bundle, if it ships one: toggle
		// switches whose key looks like a matching setting.
		let rootPlistURL = appDirectory
			.appendingPathComponent("Settings.bundle")
			.appendingPathComponent("Root.plist")
		if let dict = NSDictionary(contentsOf: rootPlistURL) as? [String: Any],
		   let specifiers = dict["PreferenceSpecifiers"] as? [[String: Any]] {
			for spec in specifiers {
				guard
					let type = spec["Type"] as? String,
					type == "PSSwitchSpecifier" || type == "PSToggleSwitchSpecifier",
					let key = spec["Key"] as? String,
					matches(key),
					let rawValue = spec["DefaultValue"],
					let value = _configValue(rawValue)
				else { continue }
				add(AppConfigFinding(
					relativePath: "Settings.bundle/Root.plist",
					key: key,
					value: value,
					source: .settingsBundle
				))
			}
		}

		// 3. Every other bundled .plist / .json file whose name
		// hints at config — signatures, frameworks, extensions,
		// localizations, and the companion Watch app never hold
		// app config.
		let appPath = appDirectory.path
		guard let enumerator = FileManager.default.enumerator(
			at: appDirectory,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		) else {
			findings.sort { $0.relativePath < $1.relativePath }
			return findings
		}

		var scanned = 0
		var parsedFiles = 0
		for case let url as URL in enumerator {
			scanned += 1
			if scanned > maxScannedEntries { break }

			let relativePath = url.path.replacingOccurrences(of: appPath + "/", with: "")
			let firstComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
			if ["_CodeSignature", "Frameworks", "PlugIns", "Watch"].contains(firstComponent) {
				continue
			}
			if relativePath.contains(".lproj/") { continue }
			if relativePath == "Info.plist" { continue }
			if relativePath.hasPrefix("Settings.bundle/") { continue }

			let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
			guard values?.isRegularFile == true else { continue }

			let ext = url.pathExtension.lowercased()
			guard ext == "plist" || ext == "json" else { continue }
			let fileName = url.deletingPathExtension().lastPathComponent.lowercased()
			guard fileNameHints.contains(where: { fileName.contains($0) }) else { continue }
			guard parsedFiles < maxFilesParsed else { break }
			parsedFiles += 1

			if ext == "plist" {
				guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { continue }
				for (key, rawValue) in dict {
					guard matches(key), let value = _configValue(rawValue) else { continue }
					add(AppConfigFinding(
						relativePath: relativePath,
						key: key,
						value: value,
						source: .plistFile
					))
				}
			} else {
				guard
					let data = try? Data(contentsOf: url),
					let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
				else { continue }
				for (key, rawValue) in dict {
					guard matches(key), let value = _configValue(rawValue) else { continue }
					add(AppConfigFinding(
						relativePath: relativePath,
						key: key,
						value: value,
						source: .jsonFile
					))
				}
			}
		}

		findings.sort {
			if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
			return $0.key < $1.key
		}
		return findings
	}

	/// Converts a plist / JSON value to a config value, or nil
	/// when it is not a Bool, number, or String. A plain `as?
	/// Bool` is not enough: numbers also bridge to Bool, so the
	/// CFBoolean type check keeps `1` and `0` numbers from being
	/// offered as flags.
	private static func _configValue(_ rawValue: Any) -> AppConfigValue? {
		if let number = rawValue as? NSNumber {
			if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
				return .bool(number.boolValue)
			}
			return .number(number.doubleValue)
		}
		if let string = rawValue as? String {
			return .string(string)
		}
		return nil
	}
}

// MARK: - Applier

enum AppConfigApplyError: Error, LocalizedError {
	case pathNotAllowed(String)
	case fileNotFound(String)
	case keyNotFound(String)
	case writeFailed(String)

	var errorDescription: String? {
		switch self {
		case .pathNotAllowed(let path):
			"\(path) is outside the app bundle."
		case .fileNotFound(let path):
			"\(path) was not found."
		case .keyNotFound(let key):
			"\(key) no longer exists in the app."
		case .writeFailed(let path):
			"Could not save \(path)."
		}
	}
}

/// Writes the staged config changes into the copied .app before
/// re-signing. Only keys that already exist are set — a missing
/// key is refused instead of invented. Throws on the first change
/// that cannot be applied, so a half-applied set is never
/// silently signed.
enum AppConfigApplier {
	static func apply(changes: [AppConfigChange], to appDirectory: URL) throws {
		for change in changes {
			let url = try _resolvedURL(for: change.relativePath, in: appDirectory)
			guard FileManager.default.fileExists(atPath: url.path) else {
				throw AppConfigApplyError.fileNotFound(change.relativePath)
			}
			if url.pathExtension.lowercased() == "json" {
				try _applyJSON(change, at: url)
			} else if change.relativePath.hasSuffix("Settings.bundle/Root.plist") {
				try _applySettingsBundle(change, at: url)
			} else {
				try _applyPlist(change, at: url)
			}
		}
	}

	private static func _applyPlist(_ change: AppConfigChange, at url: URL) throws {
		guard let dict = NSMutableDictionary(contentsOf: url) else {
			throw AppConfigApplyError.writeFailed(change.relativePath)
		}
		guard dict[change.key] != nil else {
			throw AppConfigApplyError.keyNotFound(change.relativePath + "#" + change.key)
		}
		dict[change.key] = _nsValue(change.value)
		guard dict.write(to: url, atomically: true) else {
			throw AppConfigApplyError.writeFailed(change.relativePath)
		}
	}

	private static func _applySettingsBundle(_ change: AppConfigChange, at url: URL) throws {
		guard
			let dict = NSMutableDictionary(contentsOf: url),
			let specifiers = dict["PreferenceSpecifiers"] as? NSMutableArray
		else {
			throw AppConfigApplyError.writeFailed(change.relativePath)
		}
		var found = false
		for case let spec as NSMutableDictionary in specifiers {
			if (spec["Key"] as? String) == change.key {
				spec["DefaultValue"] = _nsValue(change.value)
				found = true
			}
		}
		guard found else {
			throw AppConfigApplyError.keyNotFound(change.relativePath + "#" + change.key)
		}
		guard dict.write(to: url, atomically: true) else {
			throw AppConfigApplyError.writeFailed(change.relativePath)
		}
	}

	private static func _applyJSON(_ change: AppConfigChange, at url: URL) throws {
		do {
			let data = try Data(contentsOf: url)
			guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				throw AppConfigApplyError.writeFailed(change.relativePath)
			}
			guard dict[change.key] != nil else {
				throw AppConfigApplyError.keyNotFound(change.relativePath + "#" + change.key)
			}
			dict[change.key] = _jsonValue(change.value)
			let out = try JSONSerialization.data(
				withJSONObject: dict,
				options: [.prettyPrinted, .sortedKeys]
			)
			try out.write(to: url, options: .atomic)
		} catch let error as AppConfigApplyError {
			throw error
		} catch {
			throw AppConfigApplyError.writeFailed(change.relativePath)
		}
	}

	/// A whole number stays an integer when written back, so an
	/// app reading the key as an integer keeps seeing an integer.
	private static func _nsValue(_ value: AppConfigValue) -> Any {
		switch value {
		case .bool(let boolValue):
			return NSNumber(value: boolValue)
		case .number(let numberValue):
			if numberValue == numberValue.rounded(), abs(numberValue) < 9_000_000_000_000_000 {
				return NSNumber(value: Int(numberValue))
			}
			return NSNumber(value: numberValue)
		case .string(let stringValue):
			return stringValue as NSString
		}
	}

	private static func _jsonValue(_ value: AppConfigValue) -> Any {
		switch value {
		case .bool(let boolValue):
			return boolValue
		case .number(let numberValue):
			if numberValue == numberValue.rounded(), abs(numberValue) < 9_000_000_000_000_000 {
				return Int(numberValue)
			}
			return numberValue
		case .string(let stringValue):
			return stringValue
		}
	}

	/// Resolves a staged relative path inside the bundle, refusing
	/// anything that would escape it (`..`, absolute paths).
	private static func _resolvedURL(for relativePath: String, in appDirectory: URL) throws -> URL {
		guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
			throw AppConfigApplyError.pathNotAllowed(relativePath)
		}
		let components = relativePath.split(separator: "/").map(String.init)
		guard !components.contains(".."), !components.contains(".") else {
			throw AppConfigApplyError.pathNotAllowed(relativePath)
		}
		let url = components.reduce(appDirectory) { $0.appendingPathComponent($1) }
		guard url.path.hasPrefix(appDirectory.path + "/") else {
			throw AppConfigApplyError.pathNotAllowed(relativePath)
		}
		return url
	}
}
