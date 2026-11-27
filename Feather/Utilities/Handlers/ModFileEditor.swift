//
//  ModFileEditor.swift
//  Zenith
//
//  Zenith v2.12, item 4: edit locally stored game values (money,
//  points, ...) inside the .app bundle before signing.
//
//  Only plain-text files can be edited. Binary files — including
//  binary plists and SQLite databases — are refused honestly instead
//  of being mangled: readText throws .binaryFile and the UI says so.
//
//  Edits are staged in Options.modFileEdits (relative path inside the
//  .app → new file text) and applied by SigningHandler.modify() to the
//  copied .app in its temp work directory, before re-signing, so the
//  edited files are covered by the fresh signature.
//

import Foundation

// MARK: - Model

/// One staged text edit, applied at signing time.
struct ModFileEdit: Codable, Equatable, Identifiable {
	var id: String { relativePath }

	/// Path inside the .app bundle, e.g. `Library/data.json`.
	var relativePath: String
	/// The full new file contents, as edited by the user.
	var editedText: String
}

// MARK: - Errors

enum ModFileEditError: Error, LocalizedError {
	case binaryFile(String)
	case fileTooLarge(String)
	case pathNotAllowed(String)
	case fileNotFound(String)
	case writeFailed(String)

	var errorDescription: String? {
		switch self {
		case .binaryFile(let path):
			"\(path) is not plain text and cannot be edited."
		case .fileTooLarge(let path):
			"\(path) is too large to edit here."
		case .pathNotAllowed(let path):
			"\(path) is outside the app bundle."
		case .fileNotFound(let path):
			"\(path) was not found."
		case .writeFailed(let path):
			"Could not save \(path)."
		}
	}
}

// MARK: - Editor

enum ModFileEditor {
	/// Largest file the in-app text editor will open.
	static let maxEditableBytes = 200_000

	/// Text files inside the .app that the editor can open.
	static func editableFiles(in appDirectory: URL) -> [ModdableFile] {
		ModdabilityChecker.check(appDirectory: appDirectory).editableFiles
	}

	/// Reads a file as plain text. Throws `.binaryFile` when the
	/// contents are not UTF-8 text (binary plist, SQLite, ...).
	static func readText(of file: ModdableFile, in appDirectory: URL) throws -> String {
		guard ModdabilityChecker.textEditableExtensions.contains(
			(URL(fileURLWithPath: file.relativePath).pathExtension).lowercased()
		) else {
			throw ModFileEditError.binaryFile(file.relativePath)
		}
		guard file.size <= maxEditableBytes else {
			throw ModFileEditError.fileTooLarge(file.relativePath)
		}

		let url = try _resolvedURL(for: file.relativePath, in: appDirectory)
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw ModFileEditError.fileNotFound(file.relativePath)
		}

		let data: Data
		do {
			data = try Data(contentsOf: url)
		} catch {
			throw ModFileEditError.fileNotFound(file.relativePath)
		}
		// A NUL byte in the first bytes means binary data even when
		// the extension looks textual.
		if data.prefix(4096).contains(0) {
			throw ModFileEditError.binaryFile(file.relativePath)
		}
		guard let text = String(data: data, encoding: .utf8) else {
			throw ModFileEditError.binaryFile(file.relativePath)
		}
		return text
	}

	/// Writes every staged edit back into the .app bundle.
	/// Throws on the first edit that cannot be applied, so a
	/// half-applied set is never silently signed.
	static func apply(edits: [ModFileEdit], to appDirectory: URL) throws {
		for edit in edits {
			guard ModdabilityChecker.textEditableExtensions.contains(
				(URL(fileURLWithPath: edit.relativePath).pathExtension).lowercased()
			) else {
				throw ModFileEditError.binaryFile(edit.relativePath)
			}

			let url = try _resolvedURL(for: edit.relativePath, in: appDirectory)
			guard FileManager.default.fileExists(atPath: url.path) else {
				throw ModFileEditError.fileNotFound(edit.relativePath)
			}
			do {
				try edit.editedText.write(to: url, atomically: true, encoding: .utf8)
			} catch {
				throw ModFileEditError.writeFailed(edit.relativePath)
			}
		}
	}

	/// Resolves a staged relative path inside the bundle, refusing
	/// anything that would escape it (`..`, absolute paths).
	private static func _resolvedURL(for relativePath: String, in appDirectory: URL) throws -> URL {
		guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
			throw ModFileEditError.pathNotAllowed(relativePath)
		}
		let components = relativePath.split(separator: "/").map(String.init)
		guard !components.contains(".."), !components.contains(".") else {
			throw ModFileEditError.pathNotAllowed(relativePath)
		}
		let url = components.reduce(appDirectory) { $0.appendingPathComponent($1) }
		guard url.path.hasPrefix(appDirectory.path + "/") else {
			throw ModFileEditError.pathNotAllowed(relativePath)
		}
		return url
	}
}
