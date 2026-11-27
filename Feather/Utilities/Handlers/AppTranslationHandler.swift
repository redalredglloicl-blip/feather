
//
//  AppTranslationHandler.swift
//  Zenith
//
//  Zenith v2.12, item 22 (#79): in-app translation at signing
//  time — the LAST item of section 2 "تعديل التطبيقات" on the
//  signing screen, after #64.
//
//  What is REAL here (and what is not):
//  * DETECTION is real. The detector scans the imported .app for
//    bundled localization tables — every `*.lproj/*.strings`
//    file — and reports each table, its language, and how many
//    keys it holds. A .strings file is a property list, so it is
//    read with NSDictionary, the same mechanism SigningHandler
//    already uses for InfoPlist.strings.
//  * TRANSLATION BY TYPING is real. The user picks a target
//    language and types their own translation for each string.
//    The staged edits are written back into the copied .app's
//    .strings files by AppTranslationApplier before re-signing,
//    so the translated text is covered by the fresh signature
//    and the app shows it whenever it loads that table. The
//    original file name is kept, so nothing else in the bundle
//    needs to change.
//  * MACHINE TRANSLATION IS NOT REAL HERE. Zenith has no cloud
//    translation service, no translation API key, and no
//    on-device translation engine wired in for another app's
//    strings. The view says so plainly ("No Machine
//    Translation") and never presents typed translations as
//    automatic. Apple ships a Translation framework for iOS 18+,
//    but this target is iOS 16 and that framework translates
//    text inside Zenith itself — it cannot translate another
//    app's bundled strings.
//  * A TAP-TO-TRANSLATE RUNTIME OVERLAY is only possible through
//    the injection path, and only as a language switcher, not as
//    a live translator: the overlay dylib
//    (Resources/ZenithTranslateOverlay.m) adds a floating button
//    inside the signed app that switches which bundled .lproj
//    the app reads its strings from. It translates nothing by
//    itself — it only shows a translation that already exists
//    in the bundle (the developer's own, or the one the user
//    typed at signing time). A build step compiles it into a
//    bundled ZenithTranslate.dylib (the short name matches the
//    other two bundled dylibs: ZenithValueEditor, ZenithFPS),
//    so the toggle stages it directly with no file picker. The
//    user can still bring their own translation-overlay .dylib
//    instead, e.g. in a build where the compile step did not run.
//  * HONEST LIMITS, all stated in the UI:
//    - Only strings that already exist in a bundled .strings
//      file can be translated. Text compiled into the binary,
//      drawn as images, or fetched from a server is untouched.
//    - InfoPlist.strings is skipped here: the display name is
//      already handled by SigningHandler.
//    - If the target language already ships in the bundle
//      (e.g. the app already has ar.lproj), the developer's
//      translation is used and there is nothing to type.
//    - Only one target language per signing run: switching the
//      target clears the translations typed for the old one.
//    - A .strings file is rewritten as an XML property list
//      (the same write SigningHandler already does for
//      InfoPlist.strings). If a key is gone by signing time,
//      signing fails loudly instead of signing a half-translated
//      app.
//
//  SIGNING HOOK (coordinator, in SigningHandler.modify(), after
//  the modFileEdits block, before re-signing):
//
//    if !_options.translationPlan.edits.isEmpty {
//        try AppTranslationApplier.apply(
//            edits: _options.translationPlan.edits,
//            to: movedAppPath
//        )
//    }
//
//  OPTIONS (coordinator, OptionsManager.swift — field does not
//  exist yet, same as items 13-17):
//
//    var translationPlan: TranslationPlan
//    // default: translationPlan: TranslationPlan(targetLanguageCode: "ar", edits: [])
//
//  The overlay needs no SigningHandler change: staging goes
//  through Options.injectionFiles, which TweakHandler already
//  injects with Zsign.injectDyLib before re-signing.
//

import Foundation

// MARK: - Model

/// One bundled localization table, e.g.
/// `en.lproj/Localizable.strings`.
struct LocalizedStringsTable: Identifiable, Equatable {
	var id: String { relativePath }

	/// Path inside the .app, e.g. `en.lproj/Localizable.strings`.
	var relativePath: String
	/// File name, e.g. `Localizable.strings`.
	var fileName: String
	/// Language code from the .lproj folder, e.g. `en`, `ar`,
	/// `Base`.
	var languageCode: String
	/// Number of keys in the table.
	var keyCount: Int
	/// The table's keys and values, capped at
	/// `AppTranslationDetector.maxKeysPerTable`.
	var entries: [(key: String, value: String)]

	static func == (lhs: LocalizedStringsTable, rhs: LocalizedStringsTable) -> Bool {
		lhs.relativePath == rhs.relativePath
			&& lhs.keyCount == rhs.keyCount
			&& lhs.entries.map(\.key) == rhs.entries.map(\.key)
			&& lhs.entries.map(\.value) == rhs.entries.map(\.value)
	}
}

/// The outcome of the localization scan.
struct AppTranslationReport: Equatable {
	var tables: [LocalizedStringsTable]
	/// Language codes that already ship in the bundle.
	var bundledLanguages: [String]
	/// Total keys across all tables.
	var totalStringCount: Int
	/// How many files were enumerated.
	var scannedFileCount: Int
	/// True when at least one table had more keys than the
	/// per-table cap, so the UI must say some strings are hidden.
	var truncated: Bool
}

/// One staged translation, applied at signing time.
struct TranslationEdit: Codable, Equatable, Identifiable {
	var id: String { relativePath + "#" + key }

	/// Path inside the .app of the .strings file to rewrite.
	var relativePath: String
	/// The .strings key.
	var key: String
	/// The value the app shipped, shown for reference.
	var originalValue: String
	/// The user's typed translation.
	var translatedValue: String
}

/// The whole translation plan for one signing run: one target
/// language, and the translations typed for it.
struct TranslationPlan: Codable, Equatable {
	var targetLanguageCode: String
	var edits: [TranslationEdit]

	init(targetLanguageCode: String = "ar", edits: [TranslationEdit] = []) {
		self.targetLanguageCode = targetLanguageCode
		self.edits = edits
	}
}

// MARK: - Detector

enum AppTranslationDetector {
	/// Safety cap so a huge bundle cannot stall the signing screen.
	static let maxScannedEntries = 20000
	/// Safety cap on how many .strings tables are reported.
	static let maxTables = 40
	/// Safety cap on how many keys per table are offered for
	/// editing. A table with more keys still translates — the
	/// UI just says some strings are hidden.
	static let maxKeysPerTable = 100

	/// Languages the user can translate into. The display name
	/// is the language's own name, so no localization entry is
	/// needed for it.
	static let supportedTargetLanguages: [(code: String, name: String)] = [
		(code: "ar", name: "العربية"),
		(code: "en", name: "English"),
		(code: "fr", name: "Français"),
		(code: "es", name: "Español"),
		(code: "de", name: "Deutsch"),
		(code: "tr", name: "Türkçe"),
		(code: "fa", name: "فارسی"),
		(code: "ur", name: "اردو"),
		(code: "ru", name: "Русский"),
	]

	/// Scans `appDirectory` (a `.app` bundle) for
	/// `*.lproj/*.strings` files and reads each one as a
	/// property-list dictionary. InfoPlist.strings is skipped:
	/// the display name is already handled by SigningHandler.
	/// Synchronous — call from a background queue.
	static func detect(appDirectory: URL) -> AppTranslationReport {
		var tables: [LocalizedStringsTable] = []
		var bundledLanguages = Set<String>()
		var totalStrings = 0
		var truncated = false
		var scanned = 0

		guard let enumerator = FileManager.default.enumerator(
			at: appDirectory,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		) else {
			return AppTranslationReport(
				tables: [],
				bundledLanguages: [],
				totalStringCount: 0,
				scannedFileCount: 0,
				truncated: false
			)
		}

		let appPath = appDirectory.path
		for case let url as URL in enumerator {
			scanned += 1
			if scanned > maxScannedEntries { break }

			let relativePath = url.path.replacingOccurrences(of: appPath + "/", with: "")
			let firstComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
			if firstComponent == "_CodeSignature" || firstComponent == "Watch" { continue }
			if firstComponent == "Frameworks" || firstComponent == "PlugIns" { continue }
			guard url.pathExtension.lowercased() == "strings" else { continue }

			// Only tables inside a *.lproj folder count: a stray
			// .strings file elsewhere is not a localization table
			// the app loads by language.
			let components = relativePath.split(separator: "/").map(String.init)
			guard components.count >= 2,
				  components[0].hasSuffix(".lproj") else { continue }
			// The display-name table is SigningHandler's job.
			guard url.lastPathComponent != "InfoPlist.strings" else { continue }
			guard tables.count < maxTables else { break }

			let languageCode = String(components[0].dropLast(".lproj".count))
			bundledLanguages.insert(languageCode)

			guard let dict = NSDictionary(contentsOf: url) as? [String: String] else { continue }
			let sortedKeys = dict.keys.sorted()
			totalStrings += sortedKeys.count
			let shownKeys = Array(sortedKeys.prefix(maxKeysPerTable))
			if sortedKeys.count > maxKeysPerTable { truncated = true }
			tables.append(LocalizedStringsTable(
				relativePath: relativePath,
				fileName: url.lastPathComponent,
				languageCode: languageCode,
				keyCount: sortedKeys.count,
				entries: shownKeys.map { ($0, dict[$0] ?? "") }
			))
		}

		tables.sort {
			if $0.languageCode != $1.languageCode { return $0.languageCode < $1.languageCode }
			return $0.relativePath < $1.relativePath
		}
		return AppTranslationReport(
			tables: tables,
			bundledLanguages: bundledLanguages.sorted(),
			totalStringCount: totalStrings,
			scannedFileCount: scanned,
			truncated: truncated
		)
	}
}

// MARK: - Errors

enum AppTranslationApplyError: Error, LocalizedError {
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

// MARK: - Applier

/// Writes the staged translations into the copied .app's
/// .strings files, before re-signing. Only keys that already
/// exist are set — a missing key is refused instead of invented.
/// Throws on the first edit that cannot be applied, so a
/// half-translated set is never silently signed. The file is
/// written back as an XML property list, the same write
/// SigningHandler already does for InfoPlist.strings.
enum AppTranslationApplier {
	static func apply(edits: [TranslationEdit], to appDirectory: URL) throws {
		let byFile = Dictionary(grouping: edits, by: \.relativePath)
		for relativePath in byFile.keys.sorted() {
			let fileEdits = byFile[relativePath] ?? []
			let url = try _resolvedURL(for: relativePath, in: appDirectory)
			guard FileManager.default.fileExists(atPath: url.path) else {
				throw AppTranslationApplyError.fileNotFound(relativePath)
			}
			guard let dict = NSMutableDictionary(contentsOf: url) else {
				throw AppTranslationApplyError.writeFailed(relativePath)
			}
			for edit in fileEdits {
				guard dict[edit.key] != nil else {
					throw AppTranslationApplyError.keyNotFound(relativePath + "#" + edit.key)
				}
				dict[edit.key] = edit.translatedValue as NSString
			}
			guard dict.write(to: url, atomically: true) else {
				throw AppTranslationApplyError.writeFailed(relativePath)
			}
		}
	}

	/// Resolves a staged relative path inside the bundle, refusing
	/// anything that would escape it (`..`, absolute paths).
	private static func _resolvedURL(for relativePath: String, in appDirectory: URL) throws -> URL {
		guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
			throw AppTranslationApplyError.pathNotAllowed(relativePath)
		}
		let components = relativePath.split(separator: "/").map(String.init)
		guard !components.contains(".."), !components.contains(".") else {
			throw AppTranslationApplyError.pathNotAllowed(relativePath)
		}
		let url = components.reduce(appDirectory) { $0.appendingPathComponent($1) }
		guard url.path.hasPrefix(appDirectory.path + "/") else {
			throw AppTranslationApplyError.pathNotAllowed(relativePath)
		}
		return url
	}
}

// MARK: - Overlay injector

/// Stages the tap-to-switch-language overlay dylib for
/// injection, through the existing Options.injectionFiles path
/// (TweakHandler + Zsign.injectDyLib) — no new signing code.
///
/// A build step compiles Resources/ZenithTranslateOverlay.m into
/// a bundled ZenithTranslate.dylib, so the toggle stages it
/// directly with no file picker: Bundle.main finds it and it
/// goes straight into Options.injectionFiles. Bringing your own
/// translation-overlay .dylib still works as a fallback — any
/// dylib with "translate" in its file name can be picked and
/// staged the same way, e.g. in a build where the compile step
/// did not run and no bundled dylib is present. The view says so
/// only in that missing-dylib case.
enum TranslationOverlayInjector {
	/// Name of the compiled overlay dylib. A build step compiles
	/// Resources/ZenithTranslateOverlay.m into this bundled
	/// dylib. The short name matches the other two bundled
	/// dylibs (ZenithValueEditor, ZenithFPS).
	static let bundledDylibName = "ZenithTranslate"

	/// The bundled overlay dylib shipped in this build.
	/// Nil only in a build where the compile step did not run.
	static var bundledDylibURL: URL? {
		Bundle.main.url(forResource: bundledDylibName, withExtension: "dylib")
	}

	/// A translation-overlay dylib is recognised by name: the
	/// bundled "ZenithTranslate.dylib", or any user-supplied
	/// dylib with "translate" in its file name.
	static func isTranslateDylib(_ url: URL) -> Bool {
		url.lastPathComponent.lowercased().contains("translate")
	}

	/// True when a translation-overlay dylib is staged for injection.
	static func isStaged(in options: Options) -> Bool {
		options.injectionFiles.contains(where: isTranslateDylib)
	}

	/// The staged translation-overlay dylibs (usually one).
	static func stagedFiles(in options: Options) -> [URL] {
		options.injectionFiles.filter(isTranslateDylib)
	}

	/// Removes every staged translation-overlay dylib from the
	/// injection list, and deletes the stored copy. Other
	/// injected tweaks are untouched.
	static func unstage(from options: inout Options) {
		for url in stagedFiles(in: options) {
			FileManager.default.deleteStored(url) { _ in }
			if let index = options.injectionFiles.firstIndex(where: { $0 == url }) {
				options.injectionFiles.remove(at: index)
			}
		}
	}
}
