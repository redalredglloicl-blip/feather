
//
//  RemoveWatermarkView.swift
//  Zenith
//
//  Zenith v2.12, item 13 (#40): remove watermark overlays /
//  watermark SDKs / watermark-drawing code at signing time.
//
//  The screen scans the imported .app for watermark config values
//  (a switch that turns the watermark on, or a stored watermark
//  text), bundled watermark frameworks, and watermark code inside
//  the main executable, and reports what was found. A toggle is
//  offered ONLY for a config value that can actually be changed
//  and for a framework the detector proved is NOT linked by the
//  main executable — a linked framework would break the app at
//  launch, and code compiled into the executable cannot be removed
//  at all, so those are shown with the reason and no toggle. The
//  chosen changes are staged in Options.removeWatermarkChanges /
//  Options.removeWatermarkFrameworks and applied by
//  AppConfigApplier / WatermarkRemover at signing time, before
//  re-signing. Watermarks added server-side cannot be removed from
//  the device; the UI says so.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct RemoveWatermarkView: View {
	let app: AppInfoPresentable

	@Binding var options: Options

	@State private var _report: WatermarkReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false

	// MARK: Body
	var body: some View {
		NBList(.localized("Remove Watermark")) {
			NBSection(.localized("Remove Watermark")) {
				Text(verbatim: .localized("Remove Watermark Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if _appDirectoryMissing {
				NBSection(.localized("Remove Watermark")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			} else if _isScanning {
				NBSection(.localized("Remove Watermark")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
				}
			} else if let report = _report {
				if report.configFindings.isEmpty && report.frameworks.isEmpty && !report.foundInBinary {
					NBSection(.localized("Remove Watermark")) {
						Text(verbatim: .localized("No Watermark Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
						Text(verbatim: .localized("No Watermark Found Hint"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Server Watermark Cannot Be Removed"))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} else {
					if !report.configFindings.isEmpty {
						NBSection(.localized("Watermark Settings in This App")) {
							ForEach(report.configFindings) { finding in
								_configRow(finding)
							}
						}
					}

					if !report.frameworks.isEmpty {
						NBSection(.localized("Watermark Frameworks in This App")) {
							ForEach(report.frameworks) { framework in
								_frameworkRow(framework)
							}
						}
					}

					NBSection(.localized("Remove Watermark")) {
						if report.foundInBinary {
							Text(verbatim: .localized("Watermark In Binary"))
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
						Text(verbatim: .localized("Watermark Warning"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Server Watermark Cannot Be Removed"))
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
extension RemoveWatermarkView {
	@ViewBuilder
	private func _configRow(_ watermark: WatermarkFinding) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: watermark.finding.key)
					.font(.subheadline)
				Text(verbatim: watermark.finding.relativePath)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: watermark.finding.value.display)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: _configStatusText(for: watermark))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("", isOn: _configBinding(for: watermark))
				.labelsHidden()
				.disabled(watermark.proposedChange == nil)
		}
	}

	@ViewBuilder
	private func _frameworkRow(_ framework: DetectedWatermarkFramework) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: framework.frameworkName)
					.font(.subheadline)
				Text(verbatim: framework.relativePath)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: _frameworkStatusText(for: framework))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("", isOn: _frameworkBinding(for: framework))
				.labelsHidden()
				.disabled(!framework.isRemovable)
		}
	}

	private func _configStatusText(for watermark: WatermarkFinding) -> String {
		if watermark.proposedChange == nil {
			switch watermark.finding.value {
			case .number:
				return .localized("Watermark Cannot Change")
			default:
				return .localized("Watermark Already Off")
			}
		}
		return .localized("Watermark Will Turn Off")
	}

	private func _frameworkStatusText(for framework: DetectedWatermarkFramework) -> String {
		if !framework.linkageKnown {
			return .localized("Watermark Framework Linkage Unknown")
		}
		if framework.isLinked {
			return .localized("Watermark Framework Linked")
		}
		return .localized("Watermark Framework Not Linked")
	}

	private func _configBinding(for watermark: WatermarkFinding) -> Binding<Bool> {
		Binding(
			get: {
				options.removeWatermarkChanges.contains { $0.id == watermark.id }
			},
			set: { isOn in
				options.removeWatermarkChanges.removeAll { $0.id == watermark.id }
				if isOn, let change = watermark.proposedChange {
					options.removeWatermarkChanges.append(change)
				}
			}
		)
	}

	private func _frameworkBinding(for framework: DetectedWatermarkFramework) -> Binding<Bool> {
		Binding(
			get: {
				options.removeWatermarkFrameworks.contains(framework.relativePath)
			},
			set: { isOn in
				if isOn {
					if !options.removeWatermarkFrameworks.contains(framework.relativePath) {
						options.removeWatermarkFrameworks.append(framework.relativePath)
					}
				} else {
					options.removeWatermarkFrameworks.removeAll { $0 == framework.relativePath }
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
			let report = WatermarkDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only values still detected
				// AND still changeable, and frameworks still
				// detected AND still removable, stay selected.
				let changeable = Set(report.configFindings.compactMap(\.proposedChange).map(\.id))
				options.removeWatermarkChanges.removeAll { !changeable.contains($0.id) }
				let removable = Set(report.frameworks.filter(\.isRemovable).map(\.relativePath))
				options.removeWatermarkFrameworks.removeAll { !removable.contains($0) }
				_report = report
				_isScanning = false
			}
		}
	}
}
