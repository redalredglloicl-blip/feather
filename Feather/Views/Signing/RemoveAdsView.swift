//
//  RemoveAdsView.swift
//  Zenith
//
//  Zenith v2.12, item 8 (#23): remove ad SDKs at signing time.
//
//  The screen scans the imported .app for known ad SDK frameworks
//  and reports which were found. A toggle is offered ONLY for a
//  framework the detector proved is NOT linked by the main
//  executable — deleting a linked framework would break the app
//  at launch, and an SDK compiled into the executable cannot be
//  removed at all, so those are shown with the reason and no
//  toggle. The chosen frameworks are staged in
//  Options.removeAdsSDKs and deleted by AdSDKRemover at signing
//  time, before re-signing. Server-served ads are not inside the
//  app and cannot be removed; the UI says so.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct RemoveAdsView: View {
	let app: AppInfoPresentable
	
	@Binding var options: Options
	
	@State private var _report: AdSDKReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Remove Ads")) {
			NBSection(.localized("Remove Ads")) {
				Text(verbatim: .localized("Remove Ads Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			
			if _appDirectoryMissing {
				NBSection(.localized("Remove Ads")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			} else if _isScanning {
				NBSection(.localized("Remove Ads")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
				}
			} else if let report = _report {
				if report.sdks.isEmpty {
					NBSection(.localized("Remove Ads")) {
						Text(verbatim: .localized("No Ad SDKs Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
						Text(verbatim: .localized("Server Ads Cannot Be Removed"))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} else {
					NBSection(.localized("Ad SDKs in This App")) {
						ForEach(report.sdks) { sdk in
							_sdkRow(sdk)
						}
					}
					
					NBSection(.localized("Remove Ads")) {
						Text(verbatim: .localized("Remove Ads Warning"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Server Ads Cannot Be Removed"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Removed When You Sign"))
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
extension RemoveAdsView {
	@ViewBuilder
	private func _sdkRow(_ sdk: DetectedAdSDK) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: sdk.displayName)
					.font(.subheadline)
				Text(verbatim: sdk.frameworkName)
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: _statusText(for: sdk))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Toggle("", isOn: _binding(for: sdk))
				.labelsHidden()
				.disabled(!sdk.isRemovable)
		}
	}
	
	private func _statusText(for sdk: DetectedAdSDK) -> String {
		if sdk.relativePath == nil {
			return .localized("Ad SDK In Binary")
		}
		if !sdk.linkageKnown {
			return .localized("Ad SDK Linkage Unknown")
		}
		if sdk.isLinked {
			return .localized("Ad SDK Linked")
		}
		return .localized("Ad SDK Not Linked")
	}
	
	private func _binding(for sdk: DetectedAdSDK) -> Binding<Bool> {
		Binding(
			get: {
				guard let path = sdk.relativePath else { return false }
				return options.removeAdsSDKs.contains(path)
			},
			set: { isOn in
				guard let path = sdk.relativePath else { return }
				if isOn {
					if !options.removeAdsSDKs.contains(path) {
						options.removeAdsSDKs.append(path)
					}
				} else {
					options.removeAdsSDKs.removeAll { $0 == path }
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
			let report = AdSDKDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only frameworks still
				// detected AND still removable stay selected.
				let removable = Set(report.sdks.filter(\.isRemovable).compactMap(\.relativePath))
				options.removeAdsSDKs.removeAll { !removable.contains($0) }
				_report = report
				_isScanning = false
			}
		}
	}
}
