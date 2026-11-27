//
//  ModFileEditorView.swift
//  Zenith
//
//  Zenith v2.12, item 4 (#14): edit local game files before signing.
//  Lets the user change locally stored values (money, points, ...)
//  inside the IPA's text files (plist/json/xml/txt), then signs the
//  edited app. Binary files refuse honestly with "cannot edit this
//  file". Only offered when the moddability check (#16) found local
//  files — otherwise the row says plainly that it does not apply.
//
//  MARK: - ModFileEditorView
//
//  The section-placeable row. The coordinator drops this view into
//  the "التعديل" section on the signing screen. When the check says
//  the game is likely moddable it is a NavigationLink into the file
//  list; otherwise it is a disabled row explaining why.
//

import SwiftUI
import NimbleViews

// MARK: - ModFileEditorView

struct ModFileEditorView: View {
	var app: AppInfoPresentable
	@Binding var options: Options
	/// The shared check result (filled in by ModdingCheckView).
	/// Nil while the check is still running.
	var report: ModdabilityReport?

	private var _isOffered: Bool {
		report?.verdict == .likelyModdable
	}

	var body: some View {
		if report == nil {
			// The check is still running: say so. The old code
			// fell through to the disabled row here, so while
			// the check ran — and forever if it never completed
			// — this row looked permanently dead.
			HStack(spacing: 8) {
				ProgressView()
				VStack(alignment: .leading, spacing: 4) {
					Text(.localized("Edit Local Game Files"))
					Text(.localized("Checking if this game can be modded…"))
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		} else if _isOffered, let appDirectory = Storage.shared.getAppDirectory(for: app) {
			NavigationLink {
				ModFileEditorListView(
					appDirectory: appDirectory,
					options: $options
				)
			} label: {
				VStack(alignment: .leading, spacing: 4) {
					Text(.localized("Edit Local Game Files"))
					Text(.localized("Change values like money and points stored in local files, before signing."))
						.font(.caption)
						.foregroundColor(.secondary)
					if !options.modFileEdits.isEmpty {
						Text(.localized("Edited — will be applied when you sign."))
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
			}
		} else {
			VStack(alignment: .leading, spacing: 4) {
				Text(.localized("Edit Local Game Files"))
					.foregroundColor(.disabled())
				Text(.localized("Only works for games that keep values in local files."))
					.font(.caption)
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
}

// MARK: - ModFileEditorListView

/// The pushed list of editable text files inside the .app.
private struct ModFileEditorListView: View {
	var appDirectory: URL
	@Binding var options: Options

	@State private var _files: [ModdableFile] = []
	@State private var _loaded = false

	var body: some View {
		NBList(.localized("Edit Local Game Files"), type: .list) {
			Text(.localized("Change values like money and points stored in local files, before signing."))
				.font(.footnote)
				.foregroundColor(.secondary)

			if _loaded && _files.isEmpty {
				Text(.localized("No editable files found."))
					.font(.footnote)
					.foregroundColor(.disabled())
			} else {
				ForEach(_files) { file in
					NavigationLink {
						ModFileTextEditorView(
							file: file,
							appDirectory: appDirectory,
							options: $options
						)
					} label: {
						VStack(alignment: .leading, spacing: 4) {
							Text(file.relativePath)
								.font(.footnote)
								.lineLimit(2)
							if options.modFileEdits.contains(where: { $0.relativePath == file.relativePath }) {
								Text(.localized("Edited — will be applied when you sign."))
									.font(.caption)
									.foregroundColor(.secondary)
							}
						}
					}
				}
			}
		}
		.starfieldBackground()
		.onAppear(perform: _load)
	}

	private func _load() {
		guard !_loaded else { return }
		let appDirectory = self.appDirectory
		Task {
			let files = await Task.detached(priority: .utility) {
				ModFileEditor.editableFiles(in: appDirectory)
			}.value
			_files = files
			_loaded = true
		}
	}
}

// MARK: - ModFileTextEditorView

/// Plain-text editor for one file. Binary content is never shown
/// as editable text: it gets the honest "cannot edit" message.
/// Saving stages the edit in Options.modFileEdits; SigningHandler
/// applies it to the copied .app just before re-signing.
private struct ModFileTextEditorView: View {
	var file: ModdableFile
	var appDirectory: URL
	@Binding var options: Options

	@State private var _text = ""
	@State private var _isBinary = false
	@State private var _isTooLarge = false
	@State private var _loaded = false
	@State private var _saved = false

	private var _saveDisabled: Bool {
		!_loaded || _isBinary || _isTooLarge
			|| _text == _stagedText
	}

	private var _stagedText: String? {
		options.modFileEdits.first(where: { $0.relativePath == file.relativePath })?.editedText
	}

	var body: some View {
		NBList(file.relativePath, type: .list) {
			if !_loaded {
				ProgressView()
			} else if _isBinary {
				Text(.localized("Cannot edit this file — it is not plain text."))
					.font(.footnote)
					.foregroundColor(.disabled())
			} else if _isTooLarge {
				Text(.localized("File too large to edit here."))
					.font(.footnote)
					.foregroundColor(.disabled())
			} else {
				TextEditor(text: $_text)
					.font(.system(.body, design: .monospaced))
					.frame(minHeight: 300)
				if _saved {
					Text(.localized("Edited — will be applied when you sign."))
						.font(.footnote)
						.foregroundColor(.secondary)
				}
			}
		}
		.starfieldBackground()
		.toolbar {
			NBToolbarButton(
				.localized("Save Edit"),
				style: .text,
				placement: .topBarTrailing,
				isDisabled: _saveDisabled
			) {
				_save()
			}
		}
		.onAppear(perform: _load)
	}

	private func _load() {
		guard !_loaded else { return }
		// Re-editing keeps the staged text; otherwise load from disk.
		if let staged = _stagedText {
			_text = staged
			_loaded = true
			return
		}
		let file = self.file
		let appDirectory = self.appDirectory
		Task {
			let result = await Task.detached(priority: .utility) {
				() -> (text: String?, error: ModFileEditError?) in
				do {
					return (try ModFileEditor.readText(of: file, in: appDirectory), nil)
				} catch let error as ModFileEditError {
					return (nil, error)
				} catch {
					return (nil, .binaryFile(file.relativePath))
				}
			}.value
			if let text = result.text {
				_text = text
			} else if let error = result.error {
				switch error {
				case .binaryFile: _isBinary = true
				case .fileTooLarge: _isTooLarge = true
				default: _isBinary = true
				}
			}
			_loaded = true
		}
	}

	private func _save() {
		let edit = ModFileEdit(relativePath: file.relativePath, editedText: _text)
		if let index = options.modFileEdits.firstIndex(where: { $0.relativePath == file.relativePath }) {
			options.modFileEdits[index] = edit
		} else {
			options.modFileEdits.append(edit)
		}
		_saved = true
	}
}
