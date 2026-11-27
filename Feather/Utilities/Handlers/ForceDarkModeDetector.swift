
//
//  ForceDarkModeDetector.swift
//  Zenith
//
//  Zenith v2.12, item 21 (#64): force dark mode in any app.
//
//  The screen scans the imported .app for theming signals: the
//  Info.plist UIUserInterfaceStyle value, local appearance /
//  theme keys in bundled .plist/.json files or the app's
//  Settings.bundle (via AppConfigScanner), and whether a compiled
//  asset catalog (Assets.car) is present.
//
//  The dark mode itself is applied by the mechanism that already
//  exists: Options.appAppearance = .dark, which SigningHandler
//  writes as UIUserInterfaceStyle = Dark in Info.plist before
//  re-signing. Local theme keys found by the scan are staged in
//  Options.forceDarkModeChanges as AppConfigChange values and set
//  by the already-wired AppConfigApplier at signing time.
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * UIUserInterfaceStyle = Dark only affects apps that use
//    system colors and respect the trait. An app whose colors
//    are hardcoded in code stays light.
//  * Only local theme keys with a clear dark meaning are
//    offered (a `darkMode` flag set to false, a `theme` value of
//    "light"). A key whose meaning cannot be read from its name
//    is never guessed at — it is counted, not offered.
//  * Server-driven UI (colors and themes fetched from the
//    developer's server) cannot be forced from the device.
//  * An app that already forces Dark needs nothing; the UI says
//    so instead of offering a toggle that changes nothing.
//

import Foundation

// MARK: - Model

/// One local theme key that can be forced to dark.
struct ForceDarkModeThemeKey: Identifiable, Equatable {
	var id: String { relativePath + "#" + key }

	/// Path inside the .app, e.g. `Info.plist` or `Config.plist`.
	var relativePath: String
	/// The plist / JSON key (or Settings.bundle preference Key).
	var key: String
	/// The key's current value in the bundle.
	var currentValue: AppConfigValue
	/// The value that means dark for this key.
	var proposedValue: AppConfigValue
}

/// The outcome of the theming scan.
struct ForceDarkModeReport: Equatable {
	/// The raw UIUserInterfaceStyle value from Info.plist, if
	/// the app sets one at all.
	var currentStyle: String?
	/// True when the app forces Light in its own Info.plist.
	var forcesLight: Bool { currentStyle == "Light" }
	/// True when the app already forces Dark — nothing to do.
	var alreadyDark: Bool { currentStyle == "Dark" }
	var themeKeys: [ForceDarkModeThemeKey]
	/// True when a compiled asset catalog exists — its colors
	/// and images may already ship dark variants.
	var hasAssetCatalog: Bool
	/// Local theme-looking keys found but not offered, because
	/// their dark meaning cannot be read from the name or their
	/// value is not a Bool / String.
	var unflippableCount: Int
}

// MARK: - Detector

enum ForceDarkModeDetector {
	/// Substrings that mark a key as appearance / theme related.
	/// Matching is case-insensitive.
	static let keyPatterns = [
		"theme", "darkmode", "dark_mode", "appearance",
		"nightmode", "night_mode", "interfacestyle",
		"colormode", "color_scheme", "colorscheme",
	]
	/// Substrings in a file name that mark the whole file as
	/// theme / appearance related.
	static let fileNameHints = [
		"config", "settings", "theme", "appearance", "app",
		"preferences", "style", "color",
	]

	/// Scans `appDirectory` (a `.app` bundle) for theming
	/// signals. Synchronous — call from a background queue.
	static func detect(appDirectory: URL) -> ForceDarkModeReport {
		var currentStyle: String?
		let infoURL = appDirectory.appendingPathComponent("Info.plist")
		if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] {
			currentStyle = dict["UIUserInterfaceStyle"] as? String
		}

		let hasAssetCatalog = FileManager.default.fileExists(
			atPath: appDirectory.appendingPathComponent("Assets.car").path
		)

		let findings = AppConfigScanner.scan(
			appDirectory: appDirectory,
			keyPatterns: keyPatterns,
			fileNameHints: fileNameHints
		)

		var themeKeys: [ForceDarkModeThemeKey] = []
		var unflippableCount = 0
		for finding in findings {
			// The Info.plist style itself is handled by the main
			// toggle (Options.appAppearance), never as a row.
			if finding.relativePath == "Info.plist", finding.key == "UIUserInterfaceStyle" {
				continue
			}
			guard let proposed = _proposedValue(for: finding.key, current: finding.value) else {
				unflippableCount += 1
				continue
			}
			if proposed == finding.value {
				// Already dark — nothing to flip.
				continue
			}
			themeKeys.append(ForceDarkModeThemeKey(
				relativePath: finding.relativePath,
				key: finding.key,
				currentValue: finding.value,
				proposedValue: proposed
			))
		}

		themeKeys.sort {
			if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
			return $0.key < $1.key
		}
		return ForceDarkModeReport(
			currentStyle: currentStyle,
			themeKeys: themeKeys,
			hasAssetCatalog: hasAssetCatalog,
			unflippableCount: unflippableCount
		)
	}

	/// The dark value for a theme key, or nil when the key's dark
	/// meaning cannot be read from its name and value. Only
	/// explicit patterns are mapped — anything else is left alone.
	private static func _proposedValue(for key: String, current: AppConfigValue) -> AppConfigValue? {
		let lower = key.lowercased()
		switch current {
		case .bool:
			// A dark / night flag that is off: turn it on.
			let darkFlags = [
				"darkmode", "dark_mode", "darktheme", "dark_theme",
				"usedarkmode", "use_darkmode", "isdarkmode",
				"nightmode", "night_mode", "darkappearance",
			]
			guard darkFlags.contains(where: { lower.contains($0) }) else { return nil }
			return .bool(true)
		case .string(let value):
			// A theme / appearance name: "light", "auto" and
			// "system" all become "dark". Anything else (for
			// example a named brand theme) is not guessed at.
			let themeKeys = ["theme", "appearance", "colormode", "color_scheme", "colorscheme", "interfacestyle"]
			guard themeKeys.contains(where: { lower.contains($0) }) else { return nil }
			switch value.lowercased() {
			case "light", "auto", "system":
				return .string("dark")
			default:
				return nil
			}
		case .number:
			// A numeric theme value cannot be mapped to dark
			// without knowing its scale.
			return nil
		}
	}
}
