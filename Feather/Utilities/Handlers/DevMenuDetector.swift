//
//  DevMenuDetector.swift
//  Zenith
//
//  Zenith v2.12, item 9 (#24): find hidden developer/debug menus
//  in an imported .app bundle and offer to enable them.
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * Only LOCAL flags can be changed: a Bool key in the app's own
//    Info.plist, another bundled .plist/.json file, or a toggle in
//    the app's Settings.bundle. If no such flag exists, the UI says
//    plainly that no hidden developer menu was found — never a
//    fake toggle.
//  * A key whose name only LOOKS like a debug flag is shown with
//    its real key name, so the user sees exactly what is being
//    flipped. Only flags that already exist are set — no keys are
//    invented, because an invented key does nothing.
//  * Server-gated menus (flags fetched from the developer's
//    server, or menus with no local switch at all) cannot be
//    unlocked from the device.
//  * Flipping a local flag only asks the app to show its menu;
//    some apps read the flag once, ignore it, or gate the menu
//    behind a server check anyway, so enabling a flag is not a
//    promise the menu will appear.
//

import Foundation

// MARK: - Model

/// One local flag that may gate a hidden developer menu.
struct DevMenuFlag: Identifiable, Equatable {
	var id: String { relativePath + "#" + key }

	/// Path inside the .app, e.g. `Info.plist` or
	/// `Settings.bundle/Root.plist`.
	var relativePath: String
	/// The plist / JSON key (or Settings.bundle preference Key).
	var key: String
	/// What the row shows: the Settings.bundle Title when there
	/// is one, otherwise the key itself.
	var title: String
	var source: Source
	/// The flag's current value in the bundle.
	var currentValue: Bool

	enum Source: String, Codable {
		case infoPlist
		case plistFile
		case settingsBundle
		case jsonFile
	}
}

/// One staged flag change, applied at signing time.
struct DevMenuFlagChange: Codable, Equatable, Identifiable {
	var id: String { relativePath + "#" + key }

	var relativePath: String
	var key: String
	var value: Bool
}

/// The outcome of the developer-menu scan.
struct DevMenuReport: Equatable {
	var flags: [DevMenuFlag]
	/// How many bundled .plist files were parsed.
	var scannedPlistCount: Int
}

// MARK: - Detector

enum DevMenuDetector {
	/// Substrings that mark a key as a possible dev-menu gate.
	/// Matching is case-insensitive.
	static let keyPatterns = [
		"debug", "developer", "devmenu", "devmode", "showdebug",
		"internal", "qa", "testmode", "enabledebug", "debugmenu",
		"godmode", "cheat",
	]
	/// Substrings in a file name that mark the whole file as
	/// debug-related, so ALL of its Bool keys are candidates.
	static let fileNameHints = [
		"debug", "developer", "dev", "qa", "internal", "settings", "config",
	]
	/// Safety cap so a huge bundle cannot stall the signing screen.
	static let maxScannedEntries = 20000
	/// Safety cap on how many .plist files are parsed.
	static let maxPlistsParsed = 200

	/// Scans `appDirectory` (a `.app` bundle) for local flags that
	/// may gate a hidden developer menu. Synchronous — call from a
	/// background queue.
	static func detect(appDirectory: URL) -> DevMenuReport {
		var flags: [DevMenuFlag] = []
		var seen = Set<String>()
		var scannedPlistCount = 0

		func add(_ flag: DevMenuFlag) {
			guard seen.insert(flag.id).inserted else { return }
			flags.append(flag)
		}

		// 1. The bundle's own Info.plist.
		let infoURL = appDirectory.appendingPathComponent("Info.plist")
		if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] {
			for (key, value) in dict {
				guard let boolValue = _boolValue(value), _matchesPattern(key) else { continue }
				add(DevMenuFlag(
					relativePath: "Info.plist",
					key: key,
					title: key,
					source: .infoPlist,
					currentValue: boolValue
				))
			}
		}

		// 2. The app's Settings.bundle, if it ships one: toggle
		// switches whose title or key looks like a debug setting.
		let rootPlistURL = appDirectory
			.appendingPathComponent("Settings.bundle")
			.appendingPathComponent("Root.plist")
		if let dict = NSDictionary(contentsOf: rootPlistURL) as? [String: Any],
		   let specifiers = dict["PreferenceSpecifiers"] as? [[String: Any]] {
			scannedPlistCount += 1
			for spec in specifiers {
				guard
					let type = spec["Type"] as? String,
					type == "PSSwitchSpecifier" || type == "PSToggleSwitchSpecifier",
					let key = spec["Key"] as? String
				else { continue }
				let title = (spec["Title"] as? String) ?? key
				guard _matchesPattern(title) || _matchesPattern(key) else { continue }
				let currentValue = spec["DefaultValue"].flatMap { _boolValue($0) } ?? false
				add(DevMenuFlag(
					relativePath: "Settings.bundle/Root.plist",
					key: key,
					title: title,
					source: .settingsBundle,
					currentValue: currentValue
				))
			}
		}

		// 3. Every other bundled .plist / .json file, except
		// signatures, frameworks, extensions, localizations and
		// the companion Watch app — those never hold a dev menu.
		let appPath = appDirectory.path
		guard let enumerator = FileManager.default.enumerator(
			at: appDirectory,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		) else {
			return DevMenuReport(flags: [], scannedPlistCount: scannedPlistCount)
		}

		var scanned = 0
		var parsedPlists = 0
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
			// Only parse files whose name hints at settings or
			// debugging — parsing every bundled plist would be slow
			// and mostly noise.
			let fileName = url.deletingPathExtension().lastPathComponent.lowercased()
			guard fileNameHints.contains(where: { fileName.contains($0) }) else { continue }
			guard parsedPlists < maxPlistsParsed else { break }
			parsedPlists += 1

			let isDebugFile = ["debug", "developer", "dev", "qa", "internal"]
				.contains(where: { fileName.contains($0) })

			if ext == "plist" {
				scannedPlistCount += 1
				guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { continue }
				for (key, value) in dict {
					guard let boolValue = _boolValue(value) else { continue }
					guard isDebugFile || _matchesPattern(key) else { continue }
					add(DevMenuFlag(
						relativePath: relativePath,
						key: key,
						title: key,
						source: .plistFile,
						currentValue: boolValue
					))
				}
			} else {
				guard
					let data = try? Data(contentsOf: url),
					let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
				else { continue }
				for (key, value) in dict {
					guard let boolValue = _boolValue(value), _matchesPattern(key) else { continue }
					add(DevMenuFlag(
						relativePath: relativePath,
						key: key,
						title: key,
						source: .jsonFile,
						currentValue: boolValue
					))
				}
			}
		}

		flags.sort {
			if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
			return $0.key < $1.key
		}
		return DevMenuReport(flags: flags, scannedPlistCount: scannedPlistCount)
	}

	// MARK: - Helpers

	private static func _matchesPattern(_ text: String) -> Bool {
		let lower = text.lowercased()
		return keyPatterns.contains { lower.contains($0) }
	}

	/// Returns the Bool value of a plist / JSON value, or nil when
	/// it is not a real boolean. A plain `as? Bool` is not enough:
	/// numbers also bridge to Bool, so the CFBoolean type check
	/// keeps `1` and `0` numbers from being offered as flags.
	private static func _boolValue(_ value: Any) -> Bool? {
		guard let number = value as? NSNumber else { return nil }
		guard CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
		return number.boolValue
	}
}

// MARK: - Applier

enum DevMenuApplyError: Error, LocalizedError {
	case pathNotAllowed(String)
	case fileNotFound(String)
	case flagNotFound(String)
	case writeFailed(String)

	var errorDescription: String? {
		switch self {
		case .pathNotAllowed(let path):
			"\(path) is outside the app bundle."
		case .fileNotFound(let path):
			"\(path) was not found."
		case .flagNotFound(let flag):
			"\(flag) no longer exists in the app."
		case .writeFailed(let path):
			"Could not save \(path)."
		}
	}
}

/// Sets the chosen flags inside the copied .app before
/// re-signing. Only flags that already exist are set — a missing
/// key is refused instead of invented. Throws on the first change
/// that cannot be applied, so a half-applied set is never
/// silently signed.
enum DevMenuApplier {
	static func apply(changes: [DevMenuFlagChange], to appDirectory: URL) throws {
		for change in changes {
			let url = try _resolvedURL(for: change.relativePath, in: appDirectory)
			guard FileManager.default.fileExists(atPath: url.path) else {
				throw DevMenuApplyError.fileNotFound(change.relativePath)
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

	private static func _applyPlist(_ change: DevMenuFlagChange, at url: URL) throws {
		guard let dict = NSMutableDictionary(contentsOf: url) else {
			throw DevMenuApplyError.writeFailed(change.relativePath)
		}
		guard dict[change.key] != nil else {
			throw DevMenuApplyError.flagNotFound(change.relativePath + "#" + change.key)
		}
		dict[change.key] = change.value
		guard dict.write(to: url, atomically: true) else {
			throw DevMenuApplyError.writeFailed(change.relativePath)
		}
	}

	private static func _applySettingsBundle(_ change: DevMenuFlagChange, at url: URL) throws {
		guard
			let dict = NSMutableDictionary(contentsOf: url),
			let specifiers = dict["PreferenceSpecifiers"] as? NSMutableArray
		else {
			throw DevMenuApplyError.writeFailed(change.relativePath)
		}
		var found = false
		for case let spec as NSMutableDictionary in specifiers {
			if (spec["Key"] as? String) == change.key {
				spec["DefaultValue"] = change.value
				found = true
			}
		}
		guard found else {
			throw DevMenuApplyError.flagNotFound(change.relativePath + "#" + change.key)
		}
		guard dict.write(to: url, atomically: true) else {
			throw DevMenuApplyError.writeFailed(change.relativePath)
		}
	}

	private static func _applyJSON(_ change: DevMenuFlagChange, at url: URL) throws {
		do {
			let data = try Data(contentsOf: url)
			guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				throw DevMenuApplyError.writeFailed(change.relativePath)
			}
			guard dict[change.key] != nil else {
				throw DevMenuApplyError.flagNotFound(change.relativePath + "#" + change.key)
			}
			dict[change.key] = change.value
			let out = try JSONSerialization.data(
				withJSONObject: dict,
				options: [.prettyPrinted, .sortedKeys]
			)
			try out.write(to: url, options: .atomic)
		} catch let error as DevMenuApplyError {
			throw error
		} catch {
			throw DevMenuApplyError.writeFailed(change.relativePath)
		}
	}

	/// Resolves a staged relative path inside the bundle, refusing
	/// anything that would escape it (`..`, absolute paths).
	private static func _resolvedURL(for relativePath: String, in appDirectory: URL) throws -> URL {
		guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
			throw DevMenuApplyError.pathNotAllowed(relativePath)
		}
		let components = relativePath.split(separator: "/").map(String.init)
		guard !components.contains(".."), !components.contains(".") else {
			throw DevMenuApplyError.pathNotAllowed(relativePath)
		}
		let url = components.reduce(appDirectory) { $0.appendingPathComponent($1) }
		guard url.path.hasPrefix(appDirectory.path + "/") else {
			throw DevMenuApplyError.pathNotAllowed(relativePath)
		}
		return url
	}
}
