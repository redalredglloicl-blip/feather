//
//  ModdabilityChecker.swift
//  Zenith
//
//  Zenith v2.12, item 6: checks whether an imported (already extracted)
//  game is likely moddable, by scanning its .app bundle for locally
//  stored files. The verdict is deliberately a likelihood, never a
//  certainty: local files only hint that values live on-device, and
//  their absence only hints the game is server-verified.
//
//  The check runs against the extracted .app in Documents (see
//  Storage.getAppDirectory), which is exactly what the signing flow
//  works on — no IPA re-extraction is needed.
//

import Foundation

// MARK: - Model

/// One locally stored file found inside the .app bundle.
struct ModdableFile: Codable, Equatable, Identifiable {
	var id: String { relativePath }

	/// Path inside the .app bundle, e.g. `Library/data.json`.
	var relativePath: String
	var kind: Kind
	/// File size in bytes.
	var size: Int64

	enum Kind: String, Codable {
		/// Plain-text file the in-app editor can open
		/// (.plist XML, .json, .xml, .txt).
		case textEditable
		/// Local data store that exists but is not plain text
		/// (.sqlite/.db/.sav/.save). Listed as evidence only.
		case dataFile
	}
}

/// The outcome of the moddability check.
struct ModdabilityReport: Equatable {
	enum Verdict: Equatable {
		/// Local files were found, so the game likely keeps
		/// values on-device. Not a guarantee.
		case likelyModdable
		/// No local files were found, so the game is probably
		/// server-verified and modding likely will not work.
		case unlikelyModdable
	}

	var verdict: Verdict
	/// Text files the editor can open.
	var editableFiles: [ModdableFile]
	/// Local data stores, shown as evidence but not editable.
	var dataFiles: [ModdableFile]
	/// True when the only thing found was the bundle's own
	/// Info.plist. That file is app metadata, not game data,
	/// so it never counts towards "likely moddable" on its own.
	var foundOnlyInfoPlist: Bool
}

// MARK: - Checker

enum ModdabilityChecker {
	/// Extensions the in-app editor can open as plain text.
	static let textEditableExtensions: Set<String> = ["plist", "json", "xml", "txt"]
	/// Extensions that prove local storage but are not plain text.
	static let dataExtensions: Set<String> = ["sqlite", "sqlite3", "db", "sav", "save"]

	/// Most files listed in the UI; the verdict still counts all
	/// files found, even past this cap.
	static let maxListedFiles = 50
	/// Safety cap so a huge bundle cannot stall the signing screen.
	static let maxScannedEntries = 20000

	/// Scans `appDirectory` (a `.app` bundle) and reports a verdict.
	/// Synchronous — call from a background queue.
	static func check(appDirectory: URL) -> ModdabilityReport {
		var editableFiles: [ModdableFile] = []
		var dataFiles: [ModdableFile] = []
		var foundOnlyInfoPlist = false

		let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
		guard let enumerator = FileManager.default.enumerator(
			at: appDirectory,
			includingPropertiesForKeys: keys,
			options: [.skipsHiddenFiles]
		) else {
			return ModdabilityReport(
				verdict: .unlikelyModdable,
				editableFiles: [],
				dataFiles: [],
				foundOnlyInfoPlist: false
			)
		}

		let appPath = appDirectory.path
		var scanned = 0

		for case let url as URL in enumerator {
			scanned += 1
			if scanned > maxScannedEntries { break }

			// Skip containers that never hold game data: signatures,
			// bundled frameworks, extensions, localizations, and the
			// companion Watch app.
			let relativePath = url.path.replacingOccurrences(of: appPath + "/", with: "")
			let firstComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
			if ["_CodeSignature", "Frameworks", "PlugIns", "Watch"].contains(firstComponent) {
				continue
			}
			if relativePath.contains(".lproj/") {
				continue
			}

			let values = try? url.resourceValues(forKeys: Set(keys))
			guard values?.isRegularFile == true else { continue }

			// The main executable has no extension; skip it.
			let ext = url.pathExtension.lowercased()
			guard !ext.isEmpty else { continue }

			// The bundle's own Info.plist is metadata, not game
			// data. Remember it, but never let it alone flip the
			// verdict to "likely moddable".
			if relativePath == "Info.plist" {
				foundOnlyInfoPlist = true
				continue
			}

			let size = Int64(values?.fileSize ?? 0)
			if textEditableExtensions.contains(ext) {
				editableFiles.append(ModdableFile(
					relativePath: relativePath,
					kind: .textEditable,
					size: size
				))
			} else if dataExtensions.contains(ext) {
				dataFiles.append(ModdableFile(
					relativePath: relativePath,
					kind: .dataFile,
					size: size
				))
			}
		}

		editableFiles.sort { $0.relativePath < $1.relativePath }
		dataFiles.sort { $0.relativePath < $1.relativePath }

		let verdict: ModdabilityReport.Verdict =
			(!editableFiles.isEmpty || !dataFiles.isEmpty)
			? .likelyModdable
			: .unlikelyModdable

		return ModdabilityReport(
			verdict: verdict,
			editableFiles: Array(editableFiles.prefix(maxListedFiles)),
			dataFiles: Array(dataFiles.prefix(maxListedFiles)),
			foundOnlyInfoPlist: foundOnlyInfoPlist
		)
	}
}
