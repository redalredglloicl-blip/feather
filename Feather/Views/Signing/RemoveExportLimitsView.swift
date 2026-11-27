
//
//  RemoveExportLimitsView.swift
//  Zenith
//
//  Zenith v2.12, item 14 (#41): remove export / share limits at
//  signing time.
//
//  The screen scans the imported .app for local export limits —
//  number caps in bundled .plist / .json files, or Bool gates
//  that switch a limit on — and reports what was found. A toggle
//  is offered ONLY for a value that can actually be lifted: a
//  number cap is raised to 999999, a limit gate is switched off.
//  String caps (e.g. a quality cap stored as "720p") are shown
//  with the reason and no toggle, because rewriting them to a
//  guessed value could break the app or do nothing. The chosen
//  changes are staged in Options.removeExportLimitChanges and
//  applied by AppConfigApplier at signing time, before
//  re-signing. Limits enforced server-side cannot be removed from
//  the device; the UI says so.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct RemoveExportLimitsView: View {
	let app: AppInfoPresentable

	@Binding var options: Options

	@State private var _report: ExportLimitReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false

	// MARK: Body
	var body: some View {
		NBList(.localized("Remove Export Limits")) {
			NBSection(.localized("Remove Export Limits")) {
				Text(verbatim: .localized("Remove Export Limits Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if _appDirectoryMissing {
				NBSection(.localized("Remove Export Limits")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			} else if _isScanning {
				NBSection(.localized("Remove Export Limits")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
				}
			} else if let report = _report {
				if report.findings.isEmpty {
					NBSection(.localized("Remove Export Limits")) {
						Text(verbatim: .localized("No Export Limits Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
						Text(verbatim: .localized("No Export Limits Found Hint"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Server Export Limits Cannot Be Removed"))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} else {
					NBSection(.localized("Export Limits in This App")) {
						ForEach(report.findings) { finding in
							_limitRow(finding)
						}
					}

					NBSection(.localized("Remove Export Limits")) {
						Text(verbatim: .localized("Server Export Limits Cannot Be Removed"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Applied When You Sign"))
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
extension RemoveExportLimitsView {
	@ViewBuilder
	private func _limitRow(_ limit: ExportLimitFinding) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: limit.finding.key)
					.font(.subheadline)
				Text(verbatim: limit.finding.relativePath)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: limit.finding.value.display)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: _statusText(for: limit))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("", isOn: _binding(for: limit))
				.labelsHidden()
				.disabled(limit.proposedChange == nil)
		}
	}

	private func _statusText(for limit: ExportLimitFinding) -> String {
		guard let change = limit.proposedChange else {
			switch limit.finding.value {
			case .string:
				return .localized("Export Limit Cannot Change")
			case .number:
				return .localized("Export Limit Cannot Change")
			case .bool(let isOn):
				// A limit gate that is already off, or an export
				// gate that is already on, needs no change.
				if !isOn {
					return .localized("Export Limit Already Off")
				}
				let key = limit.finding.key.lowercased()
				if key.contains("enabled") || key.contains("allowed") {
					return .localized("Already Enabled")
				}
				return .localized("Export Limit Cannot Change")
			}
		}
		switch change.value {
		case .number:
			return .localized("Export Limit Raised")
		case .bool:
			return .localized("Export Limit Will Turn Off")
		case .string:
			return .localized("Export Limit Cannot Change")
		}
	}

	private func _binding(for limit: ExportLimitFinding) -> Binding<Bool> {
		Binding(
			get: {
				options.removeExportLimitChanges.contains { $0.id == limit.id }
			},
			set: { isOn in
				options.removeExportLimitChanges.removeAll { $0.id == limit.id }
				if isOn, let change = limit.proposedChange {
					options.removeExportLimitChanges.append(change)
				}
			}
		)
	}

	private func _scan() {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else {
			_appDirectoryMissing = true
			_isScanning = false
			return
		}
		Task.detached(priority: .userInitiated) {
			let report = ExportLimitDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only limits still detected
				// AND still liftable stay selected.
				let liftable = Set(report.findings.compactMap(\.proposedChange).map(\.id))
				options.removeExportLimitChanges.removeAll { !liftable.contains($0.id) }
				_report = report
				_isScanning = false
			}
		}
	}
}
