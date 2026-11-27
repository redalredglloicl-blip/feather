//
//  LiteVersionView.swift
//  Zenith
//
//  Zenith v2.12, item 23 (#100): Lite version of any app — strip
//  unused files/frameworks from the IPA to shrink it before
//  signing. The LAST item of section 2 "تعديل التطبيقات" on the
//  signing screen, after #79.
//
//  The screen scans the imported .app and shows every candidate
//  with its size and why it is safe — or why it cannot be
//  stripped. A toggle is offered ONLY for a candidate the
//  detector proved safe (unlinked framework, unused language
//  folder, junk file). Linked frameworks, the main language,
//  Base.lproj and anything whose safety cannot be proven are
//  shown with the reason and no toggle. The chosen paths are
//  staged in Options.liteStripPaths and deleted by
//  LiteStripRemover at signing time, before re-signing. Unused
//  images, sounds and videos are NOT offered: a resource loaded
//  by a name built at runtime looks exactly like an unused one.
//  If nothing safe can be stripped, the screen says so plainly
//  instead of showing a fake toggle.
//
//  WIRING (coordinator): drop the row into section 2
//  "تعديل التطبيقات" on the signing screen as its LAST item,
//  after #79:
//
//    LiteVersionRowView(app: app, options: $_temporaryOptions)
//
//  The coordinator must also add `liteStripPaths: [String]` to
//  Options (OptionsManager.swift) with a `[]` default, and call
//  LiteStripRemover from SigningHandler.modify() — see the hook
//  in LiteStripHandler.swift. SigningView.swift is NOT edited by
//  this file.
//

import SwiftUI
import NimbleViews

// MARK: - Row

/// The signing screen's section 2 row for item 23 (#100): title
/// with a one-to-two-line Iraqi-dialect explanation directly
/// underneath it, opening the Lite version screen.
struct LiteVersionRowView: View {
	let app: AppInfoPresentable

	@Binding var options: Options

	// MARK: Body
	var body: some View {
		NavigationLink {
			LiteVersionView(app: app, options: $options)
		} label: {
			VStack(alignment: .leading, spacing: 4) {
				Text(.localized("Lite Version"))
					.font(.subheadline)
				Text(.localized("Lite Version Row Explanation"))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}

// MARK: - View
struct LiteVersionView: View {
	let app: AppInfoPresentable

	@Binding var options: Options

	@State private var _report: LiteStripReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false

	/// Sizes of the candidates the user selected, for the
	/// "you'll save about X" line.
	private var _selectedSizeBytes: UInt64 {
		guard let report = _report else { return 0 }
		return report.items
			.filter { $0.isRemovable && options.liteStripPaths.contains($0.relativePath) }
			.reduce(0) { $0 + $1.sizeBytes }
	}

	// MARK: Body
	var body: some View {
		NBList(.localized("Lite Version")) {
			NBSection(.localized("Lite Version")) {
				Text(verbatim: .localized("Lite Version Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if _appDirectoryMissing {
				NBSection(.localized("Lite Version")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			} else if _isScanning {
				NBSection(.localized("Lite Version")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
				}
			} else if let report = _report {
				if report.items.isEmpty {
					NBSection(.localized("Lite Version")) {
						Text(verbatim: .localized("Nothing Safe to Strip"))
							.font(.footnote)
							.foregroundColor(.disabled())
						Text(verbatim: .localized("Nothing Safe to Strip Hint"))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} else {
					if !report.removableItems.isEmpty {
						NBSection(.localized("Lite Strip Candidates")) {
							ForEach(report.removableItems) { item in
								_candidateRow(item)
							}
						}
					} else {
						NBSection(.localized("Lite Version")) {
							Text(verbatim: .localized("Nothing Safe to Strip"))
								.font(.footnote)
								.foregroundColor(.disabled())
							Text(verbatim: .localized("Nothing Safe to Strip Hint"))
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
					}

					if !report.blockedItems.isEmpty {
						NBSection(.localized("Lite Strip Cannot Strip")) {
							ForEach(report.blockedItems) { item in
								_candidateRow(item)
							}
						}
					}

					NBSection(.localized("Lite Version")) {
						Text(verbatim: .localized("Lite Strip Protected Note"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Lite Strip Removed When You Sign"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						if _selectedSizeBytes > 0 {
							Text(verbatim: .localized(
								"Lite Strip Will Save",
								arguments: _formattedSize(_selectedSizeBytes)
							))
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
						Text(verbatim: .localized("Lite Strip If App Breaks"))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.starfieldBackground()
		.task { _scan() }
	}
}

// MARK: - Extension: View
extension LiteVersionView {
	@ViewBuilder
	private func _candidateRow(_ item: LiteStripCandidate) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: item.displayName)
					.font(.subheadline)
				Text(verbatim: item.relativePath + " · " + _formattedSize(item.sizeBytes))
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized(item.reasonKey))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("", isOn: _binding(for: item))
				.labelsHidden()
				.disabled(!item.isRemovable)
		}
	}

	private func _binding(for item: LiteStripCandidate) -> Binding<Bool> {
		Binding(
			get: { options.liteStripPaths.contains(item.relativePath) },
			set: { isOn in
				if isOn {
					if !options.liteStripPaths.contains(item.relativePath) {
						options.liteStripPaths.append(item.relativePath)
					}
				} else {
					options.liteStripPaths.removeAll { $0 == item.relativePath }
				}
			}
		)
	}

	private func _formattedSize(_ bytes: UInt64) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
	}

	private func _scan() {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else {
			_appDirectoryMissing = true
			_isScanning = false
			return
		}
		Task.detached(priority: .userInitiated) {
			let report = LiteStripDetector.scan(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only paths still
				// detected AND still removable stay selected.
				let removable = Set(report.removableItems.map(\.relativePath))
				options.liteStripPaths.removeAll { !removable.contains($0) }
				_report = report
				_isScanning = false
			}
		}
	}
}
