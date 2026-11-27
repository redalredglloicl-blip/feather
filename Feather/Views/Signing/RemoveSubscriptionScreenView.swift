
//
//  RemoveSubscriptionScreenView.swift
//  Zenith
//
//  Zenith v2.12, item 15 (#42): remove / bypass the subscription /
//  paywall screen at signing time.
//
//  The screen scans the imported .app for local flags that show
//  the subscription screen or gate premium, subscription SDKs,
//  and paywall screen files, and reports what was found. A toggle
//  is offered ONLY for a local Bool flag that can actually be
//  flipped — a paywall switch gets switched off, a local
//  "subscribed" flag gets switched on. Subscription SDKs and
//  paywall screen files are shown with the reason and no toggle:
//  deleting them breaks the app and unlocks nothing the server
//  verifies.
//
//  THIS REMOVES THE LOCALLY-SHOWN SCREEN ONLY. It does NOT unlock
//  server-verified premium features or subscriptions, and the UI
//  says that plainly at the top of the screen. If no local
//  subscription screen or gate is found, the screen says so
//  instead of offering a fake toggle.
//
//  The chosen changes are staged in
//  Options.removeSubscriptionScreenChanges and applied by
//  AppConfigApplier at signing time, before re-signing.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct RemoveSubscriptionScreenView: View {
	let app: AppInfoPresentable

	@Binding var options: Options

	@State private var _report: PaywallReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false

	// MARK: Body
	var body: some View {
		NBList(.localized("Remove Subscription Screen")) {
			NBSection(.localized("Remove Subscription Screen")) {
				Text(verbatim: .localized("Remove Subscription Screen Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized("Subscription Screen Warning"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if _appDirectoryMissing {
				NBSection(.localized("Remove Subscription Screen")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			} else if _isScanning {
				NBSection(.localized("Remove Subscription Screen")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
				}
			} else if let report = _report {
				if report.findings.isEmpty && report.sdks.isEmpty && report.paywallFiles.isEmpty {
					NBSection(.localized("Remove Subscription Screen")) {
						Text(verbatim: .localized("No Subscription Screen Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
						Text(verbatim: .localized("No Subscription Screen Found Hint"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Server Premium Cannot Be Unlocked"))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} else {
					if !report.findings.isEmpty {
						NBSection(.localized("Subscription Settings in This App")) {
							ForEach(report.findings) { finding in
								_flagRow(finding)
							}
						}
					}

					if !report.sdks.isEmpty {
						NBSection(.localized("Paywall SDKs in This App")) {
							ForEach(report.sdks) { sdk in
								_sdkRow(sdk)
							}
						}
					}

					if !report.paywallFiles.isEmpty {
						NBSection(.localized("Paywall Screen Files")) {
							ForEach(report.paywallFiles, id: \.self) { file in
								Text(verbatim: file)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
					}

					NBSection(.localized("Remove Subscription Screen")) {
						Text(verbatim: .localized("Server Premium Cannot Be Unlocked"))
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
extension RemoveSubscriptionScreenView {
	@ViewBuilder
	private func _flagRow(_ paywall: PaywallFinding) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: paywall.finding.key)
					.font(.subheadline)
				Text(verbatim: paywall.finding.relativePath)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: paywall.finding.value.display)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: _flagStatusText(for: paywall))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("", isOn: _flagBinding(for: paywall))
				.labelsHidden()
				.disabled(paywall.proposedChange == nil)
		}
	}

	@ViewBuilder
	private func _sdkRow(_ sdk: DetectedPaywallSDK) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: sdk.displayName)
					.font(.subheadline)
				if let frameworkName = sdk.frameworkName {
					Text(verbatim: frameworkName)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				if sdk.foundInBinary {
					Text(verbatim: .localized("Paywall SDK In Binary"))
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				Text(verbatim: .localized("Paywall SDK Cannot Be Removed"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
		}
	}

	private func _flagStatusText(for paywall: PaywallFinding) -> String {
		guard let change = paywall.proposedChange else {
			switch paywall.finding.value {
			case .bool:
				return .localized("Subscription Already Set")
			default:
				return .localized("Paywall Value Cannot Change")
			}
		}
		switch change.value {
		case .bool(let newValue):
			return newValue
				? .localized("Subscription Marked")
				: .localized("Subscription Screen Will Hide")
		default:
			return .localized("Paywall Value Cannot Change")
		}
	}

	private func _flagBinding(for paywall: PaywallFinding) -> Binding<Bool> {
		Binding(
			get: {
				options.removeSubscriptionScreenChanges.contains { $0.id == paywall.id }
			},
			set: { isOn in
				options.removeSubscriptionScreenChanges.removeAll { $0.id == paywall.id }
				if isOn, let change = paywall.proposedChange {
					options.removeSubscriptionScreenChanges.append(change)
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
			let report = PaywallDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only flags still detected
				// AND still flippable stay selected.
				let flippable = Set(report.findings.compactMap(\.proposedChange).map(\.id))
				options.removeSubscriptionScreenChanges.removeAll { !flippable.contains($0.id) }
				_report = report
				_isScanning = false
			}
		}
	}
}
