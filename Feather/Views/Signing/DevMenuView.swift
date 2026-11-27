//
//  DevMenuView.swift
//  Zenith
//
//  Zenith v2.12, item 9 (#24): unlock hidden developer/debug menus.
//
//  The screen scans the imported .app for local flags that may
//  gate a hidden developer menu — Bool keys in the app's own
//  Info.plist, other bundled .plist/.json files, or toggles in the
//  app's Settings.bundle — and offers a toggle for each flag
//  found, showing its real key name. If no flag is found, the
//  screen says plainly that no hidden developer menu was found
//  instead of showing a fake toggle. The chosen flags are staged
//  in Options.devMenuChanges and set by DevMenuApplier at signing
//  time, before re-signing. Server-gated menus cannot be unlocked
//  from the device; the UI says so.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct DevMenuView: View {
	let app: AppInfoPresentable
	
	@Binding var options: Options
	
	@State private var _report: DevMenuReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Developer Menus")) {
			NBSection(.localized("Developer Menus")) {
				Text(verbatim: .localized("Developer Menus Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			}
			
			if _appDirectoryMissing {
				NBSection(.localized("Developer Menus")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			} else if _isScanning {
				NBSection(.localized("Developer Menus")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			} else if let report = _report {
				if report.flags.isEmpty {
					NBSection(.localized("Developer Menus")) {
						Text(verbatim: .localized("No Developer Menu Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("No Developer Menu Found Hint"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("Server Menus Cannot Be Unlocked"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					}
				} else {
					NBSection(.localized("Developer Flags in This App")) {
						ForEach(report.flags) { flag in
							_flagRow(flag)
						}
					}
					
					NBSection(.localized("Developer Menus")) {
						Text(verbatim: .localized("Server Menus Cannot Be Unlocked"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("Enabled When You Sign"))
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
extension DevMenuView {
	@ViewBuilder
	private func _flagRow(_ flag: DevMenuFlag) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: flag.title)
					.font(.subheadline)
				Text(verbatim: flag.key)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: flag.relativePath)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: flag.currentValue ? .localized("Already Enabled") : .localized("Currently Off"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("", isOn: _binding(for: flag))
				.labelsHidden()
		}
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
	}
	
	private func _binding(for flag: DevMenuFlag) -> Binding<Bool> {
		Binding(
			get: {
				options.devMenuChanges.contains {
					$0.relativePath == flag.relativePath && $0.key == flag.key && $0.value
				}
			},
			set: { isOn in
				options.devMenuChanges.removeAll {
					$0.relativePath == flag.relativePath && $0.key == flag.key
				}
				if isOn {
					options.devMenuChanges.append(DevMenuFlagChange(
						relativePath: flag.relativePath,
						key: flag.key,
						value: true
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
			let report = DevMenuDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only flags still detected
				// stay selected.
				let detected = Set(report.flags.map(\.id))
				options.devMenuChanges.removeAll { !detected.contains($0.id) }
				_report = report
				_isScanning = false
			}
		}
	}
}
