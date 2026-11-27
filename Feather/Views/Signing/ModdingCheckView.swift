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
//  The section-placeable verdict card. The signing screen runs
//  the check on appear and binds the shared report state into
//  this view; the edit-files and mod-menu views read that same
//  report to decide whether they offer anything at all. This
//  view never runs the check itself — it only displays the
//  verdict (or the checking spinner, or the honest error with
//  a retry button that calls back into the signing screen).
//

import SwiftUI
import NimbleViews

// MARK: - ModdingCheckView

struct ModdingCheckView: View {
	var app: AppInfoPresentable

	/// Shared with the edit-files and mod-menu views: the
	/// signing screen fills it in, they read it to gate
	/// themselves.
	@Binding var report: ModdabilityReport?

	/// Owned by the signing screen (it runs the check on
	/// appear, so the verdict is ready before any modding
	/// sub-screen opens): true when the check could not run
	/// at all (the app's files are not on disk).
	@Binding var checkFailed: Bool

	/// Retry tap: the signing screen clears `checkFailed` and
	/// re-runs its check.
	var onRetry: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if let report {
				_verdict(report)
			} else if checkFailed {
				Text(.localized("ما قدرت أفحص ملفات هالتطبيق، حاول مرة ثانية."))
					.font(.footnote)
					.foregroundColor(.secondary)
				Button {
					onRetry()
				} label: {
					Text(.localized("إعادة الفحص"))
				}
				.buttonStyle(ZenithPressButtonStyle())
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
			Text(verbatim: .localized("and %lld more files", arguments: remaining))
				.font(.caption)
				.foregroundColor(.secondary)
		}
	}
}
