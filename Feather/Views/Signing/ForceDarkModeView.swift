
//
//  ForceDarkModeView.swift
//  Zenith
//
//  Zenith v2.12, item 21 (#64): force dark mode in any app.
//  Item 14 of the "تعديل التطبيقات" section on the signing screen,
//  after item 13 (use without account, #61).
//
//  The screen scans the imported .app for theming signals (the
//  Info.plist UIUserInterfaceStyle value, local appearance / theme
//  keys, a compiled asset catalog) and offers the force-dark
//  switch plus a toggle for each local theme key with a clear dark
//  meaning, showing its real key name.
//
//  The dark mode itself uses the mechanism that already exists:
//  turning the switch on sets Options.appAppearance = .dark on the
//  signing sheet's temporary options, which SigningHandler writes
//  as UIUserInterfaceStyle = Dark in Info.plist before re-signing.
//  Turning it off restores the previous appearance. Local theme
//  keys are staged in Options.forceDarkModeChanges and set by the
//  already-wired AppConfigApplier at signing time.
//
//  HONEST LIMITS — shown in the UI, not hidden: the system-level
//  override only affects apps that use system colors and respect
//  the trait. Hardcoded colors stay light, and server-driven UI
//  cannot be forced from the device. An app that already forces
//  Dark is shown as such, with no toggle that changes nothing.
//
//  WIRING (coordinator): drop the row into the "تعديل التطبيقات"
//  section as item 14 — the row label carries the title and the
//  1–2 line Iraqi explanation, per Reda's rule. SigningView.swift
//  is NOT edited by this file:
//
//    NavigationLink {
//        ForceDarkModeView(app: app, options: $_temporaryOptions)
//    } label: {
//        ForceDarkModeRowLabel()
//    }
//    .zenithGlassCard(cornerRadius: 12)
//    .padding(.vertical, 6)
//    .listRowSeparator(.hidden)
//
//  The coordinator also adds Options.forceDarkModeChanges (see
//  the report) and the one AppConfigApplier hook in
//  SigningHandler.modify().
//
//  MARK: - ForceDarkModeView
//  MARK: - ForceDarkModeRowLabel
//

import SwiftUI
import NimbleViews

// MARK: - View
struct ForceDarkModeView: View {
	let app: AppInfoPresentable
	
	@Binding var options: Options
	
	@State private var _report: ForceDarkModeReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false
	/// The appearance the signing sheet had before this screen
	/// touched it, restored when the switch is turned off.
	@State private var _previousAppearance: Options.AppAppearance = .default
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Force Dark Mode")) {
			NBSection(.localized("Force Dark Mode")) {
				Text(verbatim: .localized("Force Dark Mode Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
				Text(verbatim: .localized("Hardcoded Colors Cannot Be Themed"))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			}
			
			if _appDirectoryMissing {
				NBSection(.localized("Force Dark Mode")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			} else if _isScanning {
				NBSection(.localized("Force Dark Mode")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			} else if let report = _report {
				NBSection(.localized("Force Dark Mode")) {
					if report.alreadyDark {
						Text(verbatim: .localized("App Already Dark"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					} else {
						Toggle(.localized("Force Dark Mode"), isOn: _forceDarkBinding)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						if report.forcesLight {
							Text(verbatim: .localized("App Forces Light Mode"))
								.font(.footnote)
								.foregroundStyle(.secondary)
								.zenithGlassCard(cornerRadius: 12)
								.padding(.vertical, 6)
								.listRowSeparator(.hidden)
						}
					}
					if report.hasAssetCatalog {
						Text(verbatim: .localized("Asset Catalog Found"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					}
					if report.themeKeys.isEmpty {
						Text(verbatim: .localized("App Has No Theme Settings"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					}
				}
				
				if !report.themeKeys.isEmpty {
					NBSection(.localized("Theme Settings in This App")) {
						ForEach(report.themeKeys) { themeKey in
							_themeKeyRow(themeKey)
						}
					}
				}
				
				NBSection(.localized("Force Dark Mode")) {
					Text(verbatim: .localized("Enabled When You Sign"))
						.font(.footnote)
						.foregroundStyle(.secondary)
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			}
		}
		.starfieldBackground()
		.task {
			_previousAppearance = options.appAppearance
			_scan()
		}
	}
}

// MARK: - Extension: View
extension ForceDarkModeView {
	/// The main switch drives Options.appAppearance on the
	/// signing sheet's temporary options only: on = Dark for this
	/// signing run, off = whatever the sheet had before.
	private var _forceDarkBinding: Binding<Bool> {
		Binding(
			get: { options.appAppearance == .dark },
			set: { isOn in
				if isOn {
					options.appAppearance = .dark
				} else {
					options.appAppearance = _previousAppearance == .dark ? .default : _previousAppearance
				}
			}
		)
	}
	
	@ViewBuilder
	private func _themeKeyRow(_ themeKey: ForceDarkModeThemeKey) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: themeKey.key)
					.font(.subheadline)
				Text(verbatim: themeKey.relativePath)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized("Current Value Is %@", arguments: themeKey.currentValue.display))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized("Will Become %@", arguments: themeKey.proposedValue.display))
					.font(.footnote)
					.foregroundStyle(Color(hex: "#FFC778"))
			}
			Spacer()
			Toggle("", isOn: _binding(for: themeKey))
				.labelsHidden()
		}
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
	}
	
	private func _binding(for themeKey: ForceDarkModeThemeKey) -> Binding<Bool> {
		Binding(
			get: {
				options.forceDarkModeChanges.contains {
					$0.relativePath == themeKey.relativePath && $0.key == themeKey.key && $0.value == themeKey.proposedValue
				}
			},
			set: { isOn in
				options.forceDarkModeChanges.removeAll {
					$0.relativePath == themeKey.relativePath && $0.key == themeKey.key
				}
				if isOn {
					options.forceDarkModeChanges.append(AppConfigChange(
						relativePath: themeKey.relativePath,
						key: themeKey.key,
						value: themeKey.proposedValue
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
			let report = ForceDarkModeDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only theme keys still
				// detected stay selected.
				let detected = Set(report.themeKeys.map(\.id))
				options.forceDarkModeChanges.removeAll { !detected.contains($0.id) }
				_report = report
				_isScanning = false
			}
		}
	}
}

// MARK: - ForceDarkModeRowLabel

/// The signing-screen row for item 21 (#64): the title with its
/// 1–2 line Iraqi explanation underneath, per Reda's rule. The
/// coordinator uses this as the NavigationLink label.
struct ForceDarkModeRowLabel: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(.localized("Force Dark Mode"))
				.font(.headline)
			Text(.localized("Force Dark Mode Explanation"))
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(2)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
