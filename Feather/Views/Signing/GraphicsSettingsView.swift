//
//  GraphicsSettingsView.swift
//  Zenith
//
//  Zenith v2.12, item 11 (#29): unlock hidden graphics settings.
//  Section 1 "تعديل الألعاب", position 5.
//
//  Scans the game's local config for graphics-quality gates
//  (device-model restrictions, capped quality, frame-rate caps)
//  and offers to patch them before signing. The patch is staged
//  as a ModFileEdit and applied by the existing signing pipeline,
//  so the patched files are covered by the fresh signature.
//
//  Honesty: when no gate exists the view says so plainly —
//  "no hidden graphics settings found" — and never shows a fake
//  toggle. Only local config can be patched; quality locked by
//  the game server cannot be unlocked, and the view says so.
//
//  MARK: - GraphicsSettingsView
//
//  The section-placeable card. The coordinator drops this view
//  into section 1 "تعديل الألعاب" on the signing screen, after
//  the energy-limits row (position 5) and before the integrity
//  check:
//
//    GraphicsSettingsView(app: app, options: $_temporaryOptions)
//
//  SigningView.swift is NOT edited by this file.
//

import SwiftUI
import NimbleViews

// MARK: - GraphicsSettingsView

struct GraphicsSettingsView: View {
	var app: AppInfoPresentable
	@Binding var options: Options
	/// The shared moddability report (filled in by
	/// ModdingCheckView). Only used for the server-verified
	/// caution line; the scan itself is its own evidence.
	var report: ModdabilityReport? = nil

	@State private var _scan: GraphicsSettingsReport?
	@State private var _scanning = false
	@State private var _selectedGateIDs: Set<String> = []
	@State private var _stagedPaths: [String] = []
	@State private var _skippedPaths: [String] = []

	private var _selectedGates: [GraphicsGate] {
		_scan?.gates.filter { _selectedGateIDs.contains($0.id) } ?? []
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(.localized("Unlock Hidden Graphics Settings"))
				.font(.footnote)
				.fontWeight(.semibold)

			if _scan == nil {
				HStack(spacing: 8) {
					ProgressView()
					Text(.localized("Checking for hidden graphics settings…"))
						.font(.footnote)
						.foregroundColor(.secondary)
				}
			} else if let scan = _scan {
				_result(scan)
			}

			Text(.localized("Only local settings can be changed. Quality locked by the game server cannot be unlocked."))
				.font(.caption)
				.foregroundColor(.secondary)
			Text(.localized("Graphics settings only work on offline games."))
				.font(.caption)
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
		.onAppear(perform: _runScanIfNeeded)
	}

	@ViewBuilder
	private func _result(_ scan: GraphicsSettingsReport) -> some View {
		switch scan.verdict {
		case .noGates:
			Text(.localized("No hidden graphics settings found in this game."))
				.font(.footnote)
				.foregroundColor(.secondary)
			if report?.verdict == .unlikelyModdable {
				Text(.localized("No local files found — this game is probably server-verified, so modding likely will not work."))
					.font(.caption)
					.foregroundColor(.secondary)
			}
			Text(verbatim: .localized("Scanned %lld files", arguments: scan.scannedFiles))
				.font(.caption)
				.foregroundColor(.secondary)
		case .gatesFound:
			Text(.localized("Hidden graphics settings found — patch them before signing to unlock higher quality."))
				.font(.footnote)
				.foregroundColor(.secondary)
			ForEach(scan.gates) { gate in
				_gateRow(gate)
			}
			_applyButton
			if !_stagedPaths.isEmpty {
				Text(.localized("Graphics patch staged — will be applied when you sign."))
					.font(.caption)
					.foregroundColor(.secondary)
				Button {
					_removePatch()
				} label: {
					Label {
						Text(.localized("Remove Graphics Patch"))
					} icon: {
						Image(systemName: "trash")
					}
				}
				.buttonStyle(ZenithPressButtonStyle())
			}
			if !_skippedPaths.isEmpty {
				Text(.localized("Some files were already edited — those were left unchanged."))
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
	}

	@ViewBuilder
	private func _gateRow(_ gate: GraphicsGate) -> some View {
		Toggle(isOn: Binding(
			get: { _selectedGateIDs.contains(gate.id) },
			set: { isOn in
				if isOn {
					_selectedGateIDs.insert(gate.id)
				} else {
					_selectedGateIDs.remove(gate.id)
				}
			}
		)) {
			VStack(alignment: .leading, spacing: 2) {
				Text(_kindLabel(gate.kind))
					.font(.caption)
					.fontWeight(.semibold)
				Text(gate.relativePath)
					.font(.caption)
					.lineLimit(1)
				Text(verbatim: "\(gate.keyPath): \(_changeText(gate))")
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
		}
	}

	@ViewBuilder
	private var _applyButton: some View {
		Button {
			_applyPatch()
		} label: {
			Label {
				Text(.localized("Apply Graphics Patch"))
			} icon: {
				Image(systemName: "wand.and.stars")
			}
		}
		.buttonStyle(ZenithPressButtonStyle())
		.disabled(_selectedGates.isEmpty)
	}

	private func _kindLabel(_ kind: GraphicsGate.Kind) -> String {
		switch kind {
		case .qualityCap: .localized("Quality cap")
		case .deviceGate: .localized("Device gate")
		case .frameRateCap: .localized("Frame rate cap")
		}
	}

	/// "Low → High", or "Device restriction removed" for a gate
	/// whose patch deletes the restriction instead of replacing it.
	private func _changeText(_ gate: GraphicsGate) -> String {
		if gate.kind == .deviceGate {
			return .localized("Device restriction removed")
		}
		return .localized("From %@ to %@", arguments: gate.currentValue, gate.patchedValue)
	}

	private func _runScanIfNeeded() {
		guard _scan == nil && !_scanning else { return }
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else { return }
		_scanning = true
		Task {
			let result = await Task.detached(priority: .utility) {
				GraphicsSettingsPatcher.scan(appDirectory: appDirectory)
			}.value
			_scan = result
			_selectedGateIDs = Set(result.gates.map { $0.id })
			_scanning = false
			_refreshStagedState()
		}
	}

	private func _applyPatch() {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else { return }
		let result = GraphicsSettingsPatcher.stage(
			gates: _selectedGates,
			into: &options,
			appDirectory: appDirectory
		)
		_stagedPaths = result.staged
		_skippedPaths = result.skippedAlreadyEdited
	}

	private func _removePatch() {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else { return }
		GraphicsSettingsPatcher.unstage(paths: _stagedPaths, from: &options, appDirectory: appDirectory)
		_stagedPaths = []
		_refreshStagedState()
	}

	/// Re-derives which patched files are currently staged, so
	/// the "staged" note survives reopening the signing screen.
	private func _refreshStagedState() {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app),
			  let scan = _scan else { return }
		let paths = Set(scan.gates.map { $0.relativePath })
		_stagedPaths = paths.filter {
			GraphicsSettingsPatcher.isPatchStaged(for: $0, in: options, appDirectory: appDirectory)
		}.sorted()
	}
}
