//
//  ZenithStoreDetailView.swift
//  Zenith
//
//  Zenith 2.34 (Store): one store app in full — big icon, name,
//  developer, version + date + size, description, screenshots,
//  version history, and the download button ("تحديث" when the
//  manager says this is an update of an installed app).
//  Pushed from the store tab, so it lives inside the store's
//  own NavigationStack — no NBNavigationView of its own.
//

import SwiftUI
import NukeUI

// MARK: - View
struct ZenithStoreDetailView: View {
	var app: ZenithStoreApp
	/// The installed version, when the caller knows it (the Library
	/// cell does; the store tab does not — nil there, and the
	/// manager decides from what it knows).
	var installedVersion: String? = nil

	@ObservedObject private var _store = ZenithStoreManager.shared

	private var _isUpdate: Bool {
		_store.update(for: app.bundleIdentifier, installedVersion: installedVersion) != nil
	}

	private var _sortedHistory: [ZenithStoreAppVersion] {
		app.versionHistory.sorted { ($0.dateParsed ?? .distantPast) > ($1.dateParsed ?? .distantPast) }
	}

	/// "v1.2 • 23 Jul 2026" — the date part is dropped when the
	/// feed carries no parseable version date.
	private var _versionLine: String {
		var parts = ["v\(app.version)"]
		if let date = app.versionDateParsed {
			parts.append(ZenithStoreFormatters.date(date))
		}
		return parts.joined(separator: " • ")
	}

	private var _descriptionText: String {
		app.localizedDescription ?? ""
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				_header

				if _isUpdate {
					HStack(spacing: 6) {
						ZenithStoreUpdateBadge()
						Text("تحديث متوفر — إصدار أحدث من اللي عندك")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				ZenithStoreDownloadButton(app: app, installedVersion: installedVersion, fullWidth: true)

				_descriptionSection
				_screenshotsSection
				_historySection
			}
			.padding()
		}
		.starfieldBackground()
		.navigationTitle(app.name)
		.navigationBarTitleDisplayMode(.inline)
	}

	// MARK: - Header
	private var _header: some View {
		HStack(spacing: 14) {
			ZenithStoreIconView(url: app.iconURL, size: 96)

			VStack(alignment: .leading, spacing: 4) {
				Text(app.name)
					.font(.title3.bold())
					.lineLimit(2)
				Text(app.developerName ?? "مطوّر مو معروف")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				Text(_versionLine)
					.font(.caption)
					.foregroundStyle(.secondary)
				if let sizeText = ZenithStoreFormatters.size(app.size) {
					Text(sizeText)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Text(app.sourceName)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			Spacer()
		}
	}

	// MARK: - Description
	private var _descriptionSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("عن التطبيق")
				.font(.headline)
			Text(_descriptionText.isEmpty ? "ما عندنا وصف لهالتطبيق" : _descriptionText)
				.font(.body)
				.foregroundStyle(_descriptionText.isEmpty ? .secondary : .primary)
		}
	}

	// MARK: - Screenshots
	@ViewBuilder
	private var _screenshotsSection: some View {
		if !app.screenshotURLs.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				Text("صور من التطبيق")
					.font(.headline)
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 10) {
						ForEach(app.screenshotURLs, id: \.self) { url in
							LazyImage(url: url) { state in
								if let image = state.image {
									image
										.resizable()
										.scaledToFill()
								} else {
									Color(uiColor: .secondarySystemFill)
								}
							}
							.frame(width: 180, height: 320)
							.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
						}
					}
				}
			}
		}
	}

	// MARK: - Version history
	@ViewBuilder
	private var _historySection: some View {
		if !_sortedHistory.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				Text("الإصدارات السابقة")
					.font(.headline)
				ForEach(_sortedHistory, id: \.version) { entry in
					HStack {
						VStack(alignment: .leading, spacing: 2) {
							Text("v\(entry.version)")
								.font(.subheadline.bold())
							if let date = entry.dateParsed {
								Text(ZenithStoreFormatters.date(date))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						Spacer()
						if let sizeText = ZenithStoreFormatters.size(entry.size) {
							Text(sizeText)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
					.padding(.vertical, 4)
					Divider()
				}
			}
		}
	}
}
