//
//  ModdingCheckView.swift
//  Zenith
//
//  Zenith v2.12, item 6 (#16): moddability check. Runs
//  ModdabilityChecker over the extracted .app and reports a verdict
//  on the signing screen BEFORE the user tries to mod anything:
//  "likely moddable — local files found (listed)" vs "no local
//  files found — probably server-verified, modding likely won't
//  work". The wording never claims certainty.
//
//  MARK: - ModdingCheckView
//
//  The section-placeable verdict card. The coordinator drops this
//  view into the "التعديل" section on the signing screen and binds
//  the shared report state into it; the edit-files and mod-menu
//  views below read that same report to decide whether they offer
//  anything at all.
//

import SwiftUI
import NimbleViews

// MARK: - ModdingCheckView

struct ModdingCheckView: View {
	var app: AppInfoPresentable

	/// Shared with the edit-files and mod-menu views: this view
	/// fills it in, they read it to gate themselves.
	@Binding var report: ModdabilityReport?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if let report {
				_verdict(report)
			} else {
				HStack(spacing: 8) {
					ProgressView()
					Text(.localized("Checking if this game can be modded…"))
						.font(.footnote)
						.foregroundColor(.secondary)
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
		.onAppear(perform: _runCheckIfNeeded)
	}

	@ViewBuilder
	private func _verdict(_ report: ModdabilityReport) -> some View {
		switch report.verdict {
		case .likelyModdable:
			Label {
				Text(.localized("This game is likely moddable — local files found:"))
					.font(.footnote)
					.fontWeight(.semibold)
			} icon: {
				Image(systemName: "checkmark.circle")
			}
			_fileList(report)
			Text(.localized("Local files are only a hint — they do not guarantee the money or points are stored in them."))
				.font(.caption)
				.foregroundColor(.secondary)
		case .unlikelyModdable:
			Label {
				Text(.localized("No local files found — this game is probably server-verified, so modding likely will not work."))
					.font(.footnote)
					.fontWeight(.semibold)
			} icon: {
				Image(systemName: "xmark.circle")
			}
			if report.foundOnlyInfoPlist {
				Text(.localized("Only the app Info.plist was found — that is not game data, so modding probably will not work."))
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
	}

	@ViewBuilder
	private func _fileList(_ report: ModdabilityReport) -> some View {
		let shownEditable = Array(report.editableFiles.prefix(8))
		let shownData = Array(report.dataFiles.prefix(4))
		let shownCount = shownEditable.count + shownData.count
		let remaining = report.editableFiles.count + report.dataFiles.count - shownCount

		ForEach(shownEditable) { file in
			Label {
				Text(file.relativePath)
					.font(.caption)
					.lineLimit(1)
			} icon: {
				Image(systemName: "doc.text")
			}
		}

		if !shownData.isEmpty {
			Text(.localized("Data files (not editable as text):"))
				.font(.caption)
				.foregroundColor(.secondary)
				.padding(.top, 4)
			ForEach(shownData) { file in
				Label {
					Text(file.relativePath)
						.font(.caption)
						.lineLimit(1)
				} icon: {
					Image(systemName: "externaldrive")
				}
			}
		}

		if remaining > 0 {
			Text(.localized("and %lld more files", arguments: remaining))
				.font(.caption)
				.foregroundColor(.secondary)
		}
	}

	private func _runCheckIfNeeded() {
		guard report == nil else { return }
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else { return }
		Task {
			let result = await Task.detached(priority: .utility) {
				ModdabilityChecker.check(appDirectory: appDirectory)
			}.value
			report = result
		}
	}
}
