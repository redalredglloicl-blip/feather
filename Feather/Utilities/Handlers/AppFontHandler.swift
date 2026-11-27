//
//  AppFontHandler.swift
//  Zenith
//
//  Zenith v2.12, item 17 (#45): change an app's font at signing
//  time by replacing a bundled font file with one the user
//  supplies.
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * Only a font FILE bundled inside the .app can be replaced.
//    An app that uses the system fonts (San Francisco) ships no
//    font file, so there is nothing to replace — the UI says so
//    instead of showing a fake toggle.
//  * The app does NOT ship fonts. The user must supply the font
//    file (.ttf / .otf) themselves; Zenith never downloads or
//    bundles a font for them.
//  * Replacement keeps the ORIGINAL file name inside the bundle,
//    so UIAppFonts entries (which reference the file name) keep
//    working and no plist edit is needed. The new font is what
//    the app loads whenever it loads that bundled file, by name
//    or by path.
//  * A font is only as good as the file the user picks: a broken
//    or mismatched font file can make the app's text look wrong
//    or fall back to the system font. The file is replaced
//    byte-for-byte, nothing is converted.
//  * Text drawn with the system font (labels the app never gave
//    a custom font) is untouched — only text that used the
//    replaced bundled font changes.
//
//  SIGNING HOOK (coordinator, in SigningHandler.modify(), after
//  the modFileEdits block, before re-signing):
//
//    if !_options.fontReplacements.isEmpty {
//        try AppFontApplier.apply(replacements: _options.fontReplacements, to: movedAppPath)
//    }
//
//  OPTIONS (coordinator, OptionsManager.swift — field does not
//  exist yet, same as items 8/9):
//
//    var fontReplacements: [FontReplacement]
//    // default: fontReplacements: []
//

import Foundation

// MARK: - Model

/// One font file bundled inside the .app.
struct BundledFont: Identifiable, Equatable {
	var id: String { relativePath }

	/// Path inside the .app, e.g. `Fonts/Cairo-Regular.ttf`.
	var relativePath: String
	/// File name, e.g. `Cairo-Regular.ttf`.
	var fileName: String
	/// `ttf` or `otf`.
	var fileExtension: String
	/// True when the file name is listed in the bundle's
	/// UIAppFonts (Info.plist), i.e. the app registers it.
	var registeredInUIAppFonts: Bool
	/// File size in bytes.
	var fileSize: Int
}

/// One staged font replacement, applied at signing time.
struct FontReplacement: Codable, Equatable, Identifiable {
	var id: String { targetRelativePath }

	/// Path inside the .app of the bundled font to replace.
	var targetRelativePath: String
	/// The user-supplied font file, already stored by Zenith
	/// (see moveAndStore, "ZenithFont").
	var sourceFontURL: URL
	/// File name of the supplied font, shown in the UI.
	var sourceFileName: String
}

/// The outcome of the bundled-font scan.
struct AppFontReport: Equatable {
	var fonts: [BundledFont]
	/// The UIAppFonts entries from the bundle's Info.plist.
	var uiAppFontsEntries: [String]
	/// How many files were enumerated.
	var scannedFileCount: Int
}

// MARK: - Detector

enum AppFontDetector {
	/// Safety cap so a huge bundle cannot stall the signing screen.
	static let maxScannedEntries = 20000

	/// Scans `appDirectory` (a `.app` bundle) for bundled font
	/// files and reads the UIAppFonts entries from Info.plist.
	/// Synchronous — call from a background queue.
	static func detect(appDirectory: URL) -> AppFontReport {
		var uiAppFonts: [String] = []
		let infoURL = appDirectory.appendingPathComponent("Info.plist")
		if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any],
		   let entries = dict["UIAppFonts"] as? [String] {
			uiAppFonts = entries
		}
		let registeredNames = Set(uiAppFonts.map { ($0 as NSString).lastPathComponent })

		var fonts: [BundledFont] = []
		var scanned = 0
		guard let enumerator = FileManager.default.enumerator(
			at: appDirectory,
			includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
			options: [.skipsHiddenFiles]
		) else {
			return AppFontReport(fonts: [], uiAppFontsEntries: uiAppFonts, scannedFileCount: 0)
		}

		let appPath = appDirectory.path
		for case let url as URL in enumerator {
			scanned += 1
			if scanned > maxScannedEntries { break }

			let relativePath = url.path.replacingOccurrences(of: appPath + "/", with: "")
			let firstComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
			if firstComponent == "_CodeSignature" || firstComponent == "Watch" { continue }
			if relativePath.contains(".lproj/") { continue }

			let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
			guard values?.isRegularFile == true else { continue }

			let ext = url.pathExtension.lowercased()
			guard ext == "ttf" || ext == "otf" else { continue }

			let fileName = url.lastPathComponent
			fonts.append(BundledFont(
				relativePath: relativePath,
				fileName: fileName,
				fileExtension: ext,
				registeredInUIAppFonts: registeredNames.contains(fileName),
				fileSize: values?.fileSize ?? 0
			))
		}

		fonts.sort { $0.relativePath < $1.relativePath }
		return AppFontReport(
			fonts: fonts,
			uiAppFontsEntries: uiAppFonts,
			scannedFileCount: scanned
		)
	}
}

// MARK: - Errors

enum AppFontApplyError: Error, LocalizedError {
	case pathNotAllowed(String)
	case fileNotFound(String)
	case sourceMissing(String)
	case replaceFailed(String)

	var errorDescription: String? {
		switch self {
		case .pathNotAllowed(let path):
			"\(path) is outside the app bundle."
		case .fileNotFound(let path):
			"\(path) was not found."
		case .sourceMissing(let name):
			"The supplied font file \(name) is missing."
		case .replaceFailed(let path):
			"Could not replace \(path)."
		}
	}
}

// MARK: - Applier

/// Replaces the chosen bundled font files inside the copied .app
/// with the user-supplied font files, before re-signing. The
/// original file name is kept, so UIAppFonts entries keep working
/// and no plist edit is needed. Throws on the first replacement
/// that cannot be applied, so a half-applied set is never
/// silently signed.
enum AppFontApplier {
	static func apply(replacements: [FontReplacement], to appDirectory: URL) throws {
		for replacement in replacements {
			let target = try _resolvedURL(for: replacement.targetRelativePath, in: appDirectory)
			guard FileManager.default.fileExists(atPath: target.path) else {
				throw AppFontApplyError.fileNotFound(replacement.targetRelativePath)
			}
			guard FileManager.default.fileExists(atPath: replacement.sourceFontURL.path) else {
				throw AppFontApplyError.sourceMissing(replacement.sourceFileName)
			}
			do {
				try FileManager.default.removeItem(at: target)
				// Copy to the TARGET url, not the source file name:
				// the name inside the bundle must stay the same.
				try FileManager.default.copyItem(at: replacement.sourceFontURL, to: target)
			} catch {
				throw AppFontApplyError.replaceFailed(replacement.targetRelativePath)
			}
		}
	}

	/// Resolves a staged relative path inside the bundle, refusing
	/// anything that would escape it (`..`, absolute paths).
	private static func _resolvedURL(for relativePath: String, in appDirectory: URL) throws -> URL {
		guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
			throw AppFontApplyError.pathNotAllowed(relativePath)
		}
		let components = relativePath.split(separator: "/").map(String.init)
		guard !components.contains(".."), !components.contains(".") else {
			throw AppFontApplyError.pathNotAllowed(relativePath)
		}
		let url = components.reduce(appDirectory) { $0.appendingPathComponent($1) }
		guard url.path.hasPrefix(appDirectory.path + "/") else {
			throw AppFontApplyError.pathNotAllowed(relativePath)
		}
		return url
	}
}
