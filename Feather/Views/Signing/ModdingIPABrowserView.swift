//
//  ModdingIPABrowserView.swift
//  Zenith
//
//  Zenith v2.12, item 10 (#25): IPA file browser — the ENTRY point of
//  the modding flow. Lets the user browse the files inside the app
//  before signing: the extracted Payload/*.app contents, folders,
//  and file sizes. Tapping a text file previews it; anything that
//  is not plain text says so honestly instead of showing garbage.
//
//  MARK: - ModdingIPABrowserView
//
//  The section-placeable row. The coordinator drops this view into
//  the "التعديل" section on the signing screen; it is only a
//  NavigationLink row — the actual browsing happens in the pushed
//  ModdingIPABrowserListView below.
//

import SwiftUI
import NimbleViews

// MARK: - ModdingIPABrowserView

struct ModdingIPABrowserView: View {
	var app: AppInfoPresentable

	var body: some View {
		// The stored app IS the extracted Payload/*.app, so the
		// browser root is its directory (see
		// Storage.getAppDirectory). No IPA re-extraction is needed.
		if let appDirectory = Storage.shared.getAppDirectory(for: app) {
			NavigationLink {
				ModdingIPABrowserListView(
					directory: appDirectory,
					title: .localized("Browse IPA Files")
				)
			} label: {
				Label {
					Text(.localized("Browse IPA Files"))
				} icon: {
					Image(systemName: "folder")
				}
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
		} else {
			Text(.localized("Could not list files."))
				.font(.footnote)
				.foregroundColor(.disabled())
				.zenithGlassCard(cornerRadius: 12)
				.padding(.vertical, 6)
				.listRowSeparator(.hidden)
		}
	}
}

// MARK: - ModdingIPABrowserListView

/// One directory level of the browser. Folders push another copy of
/// this view; text files push a preview.
private struct ModdingIPABrowserListView: View {
	var directory: URL
	var title: String

	@State private var _entries: [ModdingIPAEntry] = []
	@State private var _loaded = false
	@State private var _loadFailed = false

	var body: some View {
		NBList(title, type: .list) {
			Text(.localized("Browse the files inside the app before signing."))
				.font(.footnote)
				.foregroundColor(.secondary)
				.zenithGlassCard(cornerRadius: 12)
				.padding(.vertical, 6)
				.listRowSeparator(.hidden)

			if _loadFailed {
				Text(.localized("Could not list files."))
					.font(.footnote)
					.foregroundColor(.disabled())
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			} else if _loaded && _entries.isEmpty {
				Text(.localized("Empty folder."))
					.font(.footnote)
					.foregroundColor(.disabled())
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			} else {
				ForEach(_entries) { entry in
					_row(entry)
				}
			}
		}
		.starfieldBackground()
		.onAppear(perform: _load)
	}

	@ViewBuilder
	private func _row(_ entry: ModdingIPAEntry) -> some View {
		if entry.isDirectory {
			NavigationLink {
				ModdingIPABrowserListView(directory: entry.url, title: entry.name)
			} label: {
				Label {
					Text(entry.name)
				} icon: {
					Image(systemName: "folder")
				}
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
		} else {
			NavigationLink {
				ModdingFilePreviewView(fileURL: entry.url, fileName: entry.name)
			} label: {
				HStack {
					Label {
						Text(entry.name)
							.lineLimit(2)
					} icon: {
						Image(systemName: ModdingIPAEntry.iconName(for: entry.url))
					}
					Spacer()
					Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
		}
	}

	private func _load() {
		guard !_loaded else { return }
		let directory = self.directory
		Task {
			let entries = await Task.detached(priority: .utility) {
				ModdingIPAEntry.list(in: directory)
			}.value
			if let entries {
				_entries = entries
				_loaded = true
			} else {
				_loadFailed = true
			}
		}
	}
}

// MARK: - ModdingFilePreviewView

/// Plain-text preview of one file. Binary files and oversized
/// files are refused with an honest message, never rendered.
private struct ModdingFilePreviewView: View {
	var fileURL: URL
	var fileName: String

	/// Largest file the preview will open.
	private static let maxPreviewBytes = 100_000

	@State private var _text: String?
	@State private var _isBinary = false
	@State private var _isTooLarge = false
	@State private var _loaded = false

	var body: some View {
		NBList(fileName, type: .list) {
			if !_loaded {
				ProgressView()
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			} else if _isBinary {
				Text(.localized("Cannot preview this file — it is not plain text."))
					.font(.footnote)
					.foregroundColor(.disabled())
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			} else if _isTooLarge {
				Text(.localized("File too large to preview here."))
					.font(.footnote)
					.foregroundColor(.disabled())
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			} else if let text = _text {
				Text(verbatim: text)
					.font(.system(.body, design: .monospaced))
					.textSelection(.enabled)
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			}
		}
		.starfieldBackground()
		.onAppear(perform: _load)
	}

	private func _load() {
		guard !_loaded else { return }
		let fileURL = self.fileURL
		Task {
			let result = await Task.detached(priority: .utility) {
				() -> (text: String?, isBinary: Bool, isTooLarge: Bool) in
				guard
					let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
					size <= maxPreviewBytes
				else {
					return (nil, false, true)
				}
				guard let data = try? Data(contentsOf: fileURL) else {
					return (nil, true, false)
				}
				if data.prefix(4096).contains(0) {
					return (nil, true, false)
				}
				guard let text = String(data: data, encoding: .utf8) else {
					return (nil, true, false)
				}
				return (text, false, false)
			}.value
			_text = result.text
			_isBinary = result.isBinary
			_isTooLarge = result.isTooLarge
			_loaded = true
		}
	}
}

// MARK: - ModdingIPAEntry

private struct ModdingIPAEntry: Identifiable {
	var id: String { url.path }

	var url: URL
	var name: String
	var isDirectory: Bool
	var size: Int64

	/// Lists one directory: folders first, then files, each
	/// alphabetical. Returns nil when the directory cannot be read.
	static func list(in directory: URL) -> [ModdingIPAEntry]? {
		guard let urls = try? FileManager.default.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
			options: [.skipsHiddenFiles]
		) else {
			return nil
		}

		var entries: [ModdingIPAEntry] = []
		for url in urls {
			let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
			entries.append(ModdingIPAEntry(
				url: url,
				name: url.lastPathComponent,
				isDirectory: values?.isDirectory ?? false,
				size: Int64(values?.fileSize ?? 0)
			))
		}
		entries.sort {
			if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
			return $0.name.localizedStandardCompare($1.name) == .orderedAscending
		}
		return entries
	}

	/// SF Symbol for a file row. Text files get the text glyph so
	/// the user can tell at a glance what is previewable.
	static func iconName(for url: URL) -> String {
		switch url.pathExtension.lowercased() {
		case "plist", "json", "xml", "txt":
			"doc.text"
		case "sqlite", "sqlite3", "db", "sav", "save":
			"externaldrive"
		case "png", "jpg", "jpeg":
			"photo"
		case "dylib":
			"puzzlepiece"
		default:
			"doc"
		}
	}
}
