//
//  AnimationSpeedView.swift
//  Zenith
//
//  Zenith v2.12, item 18 (#46): speed up an app's animations at
//  signing time — item 11 of the "تعديل التطبيقات" section on the
//  signing screen, after #45.
//
//  The screen scans the imported .app's bundled .plist / .json
//  config files for numeric animation-duration keys and offers to
//  shorten each one to half its value, before re-signing. The
//  chosen shortenings are staged in
//  Options.animationDurationChanges and set by
//  AnimationSpeedApplier at signing time, before re-signing.
//  Animations hardcoded in the binary cannot be patched — if no
//  duration key is found, the screen says so plainly instead of
//  showing a fake toggle.
//
//  WIRING (coordinator): drop this view into the "تعديل
//  التطبيقات" section on the signing screen as item 11, after
//  #45:
//
//    NavigationLink(.localized("Speed Up Animations")) {
//        AnimationSpeedView(
//            app: app,
//            options: $_temporaryOptions
//        )
//    }
//
//  The coordinator must also add `animationDurationChanges:
//  [AnimationDurationChange]` to Options (OptionsManager.swift)
//  with a `[]` default, and call AnimationSpeedApplier from
//  SigningHandler.modify() — see the hook in
//  AnimationSpeedHandler.swift.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct AnimationSpeedView: View {
	let app: AppInfoPresentable

	@Binding var options: Options

	@State private var _report: AnimationSpeedReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false

	// MARK: Body
	var body: some View {
		NBList(.localized("Speed Up Animations")) {
			NBSection(.localized("Speed Up Animations")) {
				Text(verbatim: .localized("Speed Up Animations Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if _appDirectoryMissing {
				NBSection(.localized("Speed Up Animations")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			} else if _isScanning {
				NBSection(.localized("Speed Up Animations")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
				}
			} else if let report = _report {
				if report.keys.isEmpty {
					NBSection(.localized("Speed Up Animations")) {
						Text(verbatim: .localized("No Animation Durations Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
						Text(verbatim: .localized("No Animation Durations Hint"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Hardcoded Animations Cannot Be Sped Up"))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} else {
					NBSection(.localized("Animation Durations in This App")) {
						ForEach(report.keys) { key in
							_keyRow(key)
						}
					}

					NBSection(.localized("Speed Up Animations")) {
						Text(verbatim: .localized("Animation Speed Warning"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Hardcoded Animations Cannot Be Sped Up"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Halved When You Sign"))
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
extension AnimationSpeedView {
	@ViewBuilder
	private func _keyRow(_ key: AnimationDurationKey) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: key.keyPath)
					.font(.subheadline)
				Text(verbatim: key.relativePath)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized("Current Duration Value", arguments: _format(key.originalValue)))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized("New Duration Value", arguments: _format(key.newValue)))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("", isOn: _binding(for: key))
				.labelsHidden()
		}
	}

	private func _binding(for key: AnimationDurationKey) -> Binding<Bool> {
		Binding(
			get: {
				options.animationDurationChanges.contains {
					$0.relativePath == key.relativePath && $0.keyPath == key.keyPath
				}
			},
			set: { isOn in
				options.animationDurationChanges.removeAll {
					$0.relativePath == key.relativePath && $0.keyPath == key.keyPath
				}
				if isOn {
					options.animationDurationChanges.append(AnimationDurationChange(
						relativePath: key.relativePath,
						keyPath: key.keyPath,
						originalValue: key.originalValue,
						newValue: key.newValue
					))
				}
			}
		)
	}

	/// Short human-readable seconds, e.g. `0.3` or `1.25`.
	private func _format(_ value: Double) -> String {
		String(format: "%g", value)
	}

	private func _scan() {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else {
			_appDirectoryMissing = true
			_isScanning = false
			return
		}
		Task.detached(priority: .userInitiated) {
			let report = AnimationSpeedDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only keys still detected
				// stay selected.
				let detected = Set(report.keys.map(\.id))
				options.animationDurationChanges.removeAll { !detected.contains($0.id) }
				_report = report
				_isScanning = false
			}
		}
	}
}
