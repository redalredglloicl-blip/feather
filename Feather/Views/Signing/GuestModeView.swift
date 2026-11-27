
//
//  GuestModeView.swift
//  Zenith
//
//  Zenith v2.12, item 20 (#61): use an app without an account.
//  Item 13 of the "تعديل التطبيقات" section on the signing screen,
//  after item 12 (change location, #60) and before item 14
//  (force dark mode, #64).
//
//  The screen scans the imported .app for local login /
//  onboarding gates — Bool keys in the app's own Info.plist,
//  other bundled .plist/.json files, or toggles in the app's
//  Settings.bundle — and offers a toggle for each gate whose
//  guest meaning is clear from its name, showing its real key
//  name. If no local gate is found, the screen says plainly that
//  the app cannot be opened without an account instead of showing
//  a fake toggle. The chosen flips are staged in
//  Options.guestLoginChanges and set by the already-wired
//  AppConfigApplier at signing time, before re-signing.
//
//  HONEST LIMITS — shown in the UI, not hidden: most account
//  systems verify server-side and CANNOT be bypassed from the
//  device. A flipped local gate only asks the app to skip its own
//  login screen; some apps ignore the flag or check the account
//  on their server anyway.
//
//  WIRING (coordinator): drop the row into the "تعديل التطبيقات"
//  section as item 13 — the row label carries the title and the
//  1–2 line Iraqi explanation, per Reda's rule. SigningView.swift
//  is NOT edited by this file:
//
//    NavigationLink {
//        GuestModeView(app: app, options: $_temporaryOptions)
//    } label: {
//        GuestModeRowLabel()
//    }
//
//  The coordinator also adds Options.guestLoginChanges (see the
//  report) and the one AppConfigApplier hook in
//  SigningHandler.modify().
//
//  MARK: - GuestModeView
//  MARK: - GuestModeRowLabel
//

import SwiftUI
import NimbleViews

// MARK: - View
struct GuestModeView: View {
	let app: AppInfoPresentable
	
	@Binding var options: Options
	
	@State private var _report: GuestLoginReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Use Without Account")) {
			NBSection(.localized("Use Without Account")) {
				Text(verbatim: .localized("Guest Mode Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			
			if _appDirectoryMissing {
				NBSection(.localized("Use Without Account")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			} else if _isScanning {
				NBSection(.localized("Use Without Account")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
				}
			} else if let report = _report {
				if report.gates.isEmpty {
					NBSection(.localized("Use Without Account")) {
						Text(verbatim: .localized("No Login Gate Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
						Text(verbatim: .localized("No Login Gate Found Hint"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Server Accounts Cannot Be Bypassed"))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} else {
					NBSection(.localized("Login Gates in This App")) {
						ForEach(report.gates) { gate in
							_gateRow(gate)
						}
					}
					
					NBSection(.localized("Use Without Account")) {
						Text(verbatim: .localized("Server Accounts Cannot Be Bypassed"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Enabled When You Sign"))
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
extension GuestModeView {
	@ViewBuilder
	private func _gateRow(_ gate: GuestLoginGate) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: gate.key)
					.font(.subheadline)
				Text(verbatim: gate.relativePath)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized("Current Value Is %@", arguments: gate.currentValue.display))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized("Will Become %@", arguments: gate.proposedValue.display))
					.font(.footnote)
					.foregroundStyle(Color(hex: "#FFC778"))
			}
			Spacer()
			Toggle("", isOn: _binding(for: gate))
				.labelsHidden()
		}
	}
	
	private func _binding(for gate: GuestLoginGate) -> Binding<Bool> {
		Binding(
			get: {
				options.guestLoginChanges.contains {
					$0.relativePath == gate.relativePath && $0.key == gate.key && $0.value == gate.proposedValue
				}
			},
			set: { isOn in
				options.guestLoginChanges.removeAll {
					$0.relativePath == gate.relativePath && $0.key == gate.key
				}
				if isOn {
					options.guestLoginChanges.append(AppConfigChange(
						relativePath: gate.relativePath,
						key: gate.key,
						value: gate.proposedValue
					))
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
			let report = GuestLoginDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only gates still detected
				// stay selected.
				let detected = Set(report.gates.map(\.id))
				options.guestLoginChanges.removeAll { !detected.contains($0.id) }
				_report = report
				_isScanning = false
			}
		}
	}
}

// MARK: - GuestModeRowLabel

/// The signing-screen row for item 20 (#61): the title with its
/// 1–2 line Iraqi explanation underneath, per Reda's rule. The
/// coordinator uses this as the NavigationLink label.
struct GuestModeRowLabel: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(.localized("Use Without Account"))
				.font(.headline)
			Text(.localized("Use Without Account Explanation"))
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(2)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
