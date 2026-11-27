
//
//  StopForcedUpdatesView.swift
//  Zenith
//
//  Zenith v2.12, item 16 (#43): stop the target app's own forced
//  in-app update prompts at signing time.
//
//  (This is about the APP being signed, not about Zenith itself —
//  Zenith's own forced update lives in ForcedUpdateManager and is
//  untouched here.)
//
//  The screen scans the imported .app for local forced-update
//  config — a Bool flag that forces an update, or a locally stored
//  minimum version / build number — and reports what was found. A
//  toggle is offered ONLY for a value that can actually be
//  changed: a force flag gets switched off, a minimum version gets
//  lowered to 1.0.0, a minimum build number gets lowered to 1.
//  Update-check endpoints (URLs) are shown with the reason and no
//  toggle, because patching them could break the app and a server
//  that answers "update required" enforces the update anyway. The
//  chosen changes are staged in Options.stopForcedUpdateChanges
//  and applied by AppConfigApplier at signing time, before
//  re-signing. Server-side enforcement cannot be stopped from the
//  device; the UI says so.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct StopForcedUpdatesView: View {
	let app: AppInfoPresentable

	@Binding var options: Options

	@State private var _report: AppForcedUpdateReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false

	// MARK: Body
	var body: some View {
		NBList(.localized("Stop Forced Updates")) {
			NBSection(.localized("Stop Forced Updates")) {
				Text(verbatim: .localized("Stop Forced Updates Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			}

			if _appDirectoryMissing {
				NBSection(.localized("Stop Forced Updates")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			} else if _isScanning {
				NBSection(.localized("Stop Forced Updates")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			} else if let report = _report {
				if report.findings.isEmpty {
					NBSection(.localized("Stop Forced Updates")) {
						Text(verbatim: .localized("No Forced Update Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("No Forced Update Found Hint"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("Server Forced Update Cannot Be Stopped"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					}
				} else {
					NBSection(.localized("Forced Update Settings in This App")) {
						ForEach(report.findings) { finding in
							_findingRow(finding)
						}
					}

					NBSection(.localized("Stop Forced Updates")) {
						Text(verbatim: .localized("Server Forced Update Cannot Be Stopped"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("Applied When You Sign"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					}
				}
			}
		}
		.starfieldBackground()
		.task { _scan() }
	}
}

// MARK: - Extension: View
extension StopForcedUpdatesView {
	@ViewBuilder
	private func _findingRow(_ update: AppForcedUpdateFinding) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: update.finding.key)
					.font(.subheadline)
				Text(verbatim: update.finding.relativePath)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: update.finding.value.display)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: _statusText(for: update))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("", isOn: _binding(for: update))
				.labelsHidden()
				.disabled(update.proposedChange == nil)
		}
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
	}

	private func _statusText(for update: AppForcedUpdateFinding) -> String {
		if update.isEndpoint {
			return .localized("Update Endpoint Cannot Change")
		}
		guard let change = update.proposedChange else {
			return .localized("Forced Update Already Off")
		}
		switch change.value {
		case .bool:
			return .localized("Forced Update Will Stop")
		case .string:
			return .localized("Minimum Version Will Lower")
		case .number:
			return .localized("Minimum Version Will Lower")
		}
	}

	private func _binding(for update: AppForcedUpdateFinding) -> Binding<Bool> {
		Binding(
			get: {
				options.stopForcedUpdateChanges.contains { $0.id == update.id }
			},
			set: { isOn in
				options.stopForcedUpdateChanges.removeAll { $0.id == update.id }
				if isOn, let change = update.proposedChange {
					options.stopForcedUpdateChanges.append(change)
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
			let report = AppForcedUpdateDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only values still detected
				// AND still changeable stay selected.
				let changeable = Set(report.findings.compactMap(\.proposedChange).map(\.id))
				options.stopForcedUpdateChanges.removeAll { !changeable.contains($0.id) }
				_report = report
				_isScanning = false
			}
		}
	}
}
