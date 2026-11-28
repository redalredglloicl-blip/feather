//
//  ZenithStoreCardView.swift
//  Zenith
//
//  Zenith 2.34 (Store): shared store cards and rows — one place,
//  reused by the store tab and the store detail screen. Peach
//  #FFC778, Iraqi strings, no emoji. App icons come from the feed
//  icon URLs (Nuke LazyImage, same pattern as FRIconCellView).
//  The download button never fakes progress: it shows "تنزيل"
//  (or "تحديث" for an update), then "جاي ينزل..." while a real
//  DownloadManager download for that URL is active, and a
//  one-time confirmation when the tap started a download the
//  manager has not surfaced yet.
//  Zenith 2.37: card text can no longer be clipped — every text
//  stack carries .fixedSize(horizontal: false, vertical: true),
//  so a multi-line name inside a scroll view / grid is measured
//  at its real height instead of being squeezed (that squeeze
//  cut the featured-card names off above the visible area on
//  Reda's phone in 2.36). Names also reserve their full two-line
//  height, so cards in one row stay the same height.
//

import SwiftUI
import NukeUI

// MARK: - Shared formatters
enum ZenithStoreFormatters {
	static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .none
		return formatter
	}()

	static func date(_ date: Date) -> String {
		dateFormatter.string(from: date)
	}

	static func size(_ bytes: Int64?) -> String? {
		guard let bytes else { return nil }
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		return formatter.string(fromByteCount: bytes)
	}
}

// MARK: - App icon (feed URL, Nuke LazyImage)
struct ZenithStoreIconView: View {
	var url: URL?
	var size: CGFloat = 56

	var body: some View {
		if let url {
			LazyImage(url: url) { state in
				if let image = state.image {
					image.appIconStyle(size: size)
				} else {
					Image("App_Unknown").appIconStyle(size: size)
				}
			}
		} else {
			Image("App_Unknown").appIconStyle(size: size)
		}
	}
}

// MARK: - Peach "تحديث" pill
struct ZenithStoreUpdateBadge: View {
	var body: some View {
		Text("تحديث")
			.font(.caption.bold())
			.foregroundStyle(.black)
			.padding(.horizontal, 8)
			.padding(.vertical, 3)
			.background(Color(hex: "#FFC778"), in: Capsule())
	}
}

// MARK: - Error banner + retry (shared by the Store home and both section screens)
struct ZenithStoreErrorBannerView: View {
	var message: String

	@ObservedObject private var _store = ZenithStoreManager.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(message)
				.font(.subheadline)
			Button("حاول مرة ثانية") {
				Task { await _store.refresh() }
			}
			.buttonStyle(ZenithPressButtonStyle())
			.foregroundStyle(Color(hex: "#FFC778"))
		}
		.padding(14)
		.zenithGlassCard()
	}
}

// MARK: - Download button
/// "تنزيل" / "تحديث" (when the manager says this app is an update
/// of an installed one) → "جاي ينزل..." while a real download for
/// this URL is active in DownloadManager, "كمّل التنزيل" when it
/// was paused by hand (tapping resumes it through download(_:)).
/// The button is never nested inside a NavigationLink label, so a
/// tap on it never opens the detail screen by accident.
struct ZenithStoreDownloadButton: View {
	var app: ZenithStoreApp
	var installedVersion: String? = nil
	var fullWidth: Bool = false

	@ObservedObject private var _store = ZenithStoreManager.shared
	@ObservedObject private var _downloads = DownloadManager.shared
	@State private var _started = false

	private var _isUpdate: Bool {
		_store.update(for: app.bundleIdentifier, installedVersion: installedVersion) != nil
	}

	/// The live DownloadManager download for this app's URL, if any.
	/// The feed download URL is optional (v2 feeds can lack one),
	/// so there is no active download without it.
	private var _activeDownload: Download? {
		guard let downloadURL = app.downloadURL else { return nil }
		return _downloads.downloads.first { $0.url == downloadURL }
	}

	private var _label: String {
		if app.downloadURL == nil { return "ما بيه رابط" }
		if let active = _activeDownload {
			switch active.status {
			case .downloading: return "جاي ينزل..."
			case .paused: return "كمّل التنزيل"
			case .failed: return "حاول مرة ثانية"
			case .completed: return "نزل"
			}
		}
		if _started { return "بلّش التنزيل — شوفه بتبويب التنزيلات" }
		return _isUpdate ? "تحديث" : "تنزيل"
	}

	var body: some View {
		Button {
			_started = true
			_store.download(app)
		} label: {
			Text(_label)
				.font(.subheadline.bold())
				.foregroundStyle(.black)
				.padding(.horizontal, 14)
				.padding(.vertical, 7)
				.frame(maxWidth: fullWidth ? .infinity : nil)
				.background(Color(hex: "#FFC778"), in: Capsule())
		}
		.buttonStyle(ZenithPressButtonStyle())
		.disabled(app.downloadURL == nil || _activeDownload?.status == .downloading)
	}
}

// MARK: - List row (icon + name + developer + version + size + button)
struct ZenithStoreRowView: View {
	var app: ZenithStoreApp

	@ObservedObject private var _store = ZenithStoreManager.shared

	var body: some View {
		HStack(spacing: 12) {
			NavigationLink(destination: ZenithStoreDetailView(app: app)) {
				HStack(spacing: 12) {
					ZenithStoreIconView(url: app.iconURL, size: 56)
					VStack(alignment: .leading, spacing: 2) {
						HStack(spacing: 6) {
							Text(app.name)
								.font(.headline)
								.lineLimit(1)
							if _store.update(for: app.bundleIdentifier, installedVersion: nil) != nil {
								ZenithStoreUpdateBadge()
							}
						}
						Text(app.developerName ?? "مطوّر مو معروف")
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.lineLimit(1)
						Text("v\(app.version)" + (ZenithStoreFormatters.size(app.size).map { " • \($0)" } ?? ""))
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
					// Never squeeze the text vertically: the row
					// must measure at the text's real height.
					.fixedSize(horizontal: false, vertical: true)
				}
				.contentShape(Rectangle())
			}
			.foregroundStyle(.primary)

			Spacer(minLength: 8)

			ZenithStoreDownloadButton(app: app)
		}
		.padding(.vertical, 4)
	}
}

// MARK: - Featured card (large, horizontal scroll)
struct ZenithStoreFeaturedCardView: View {
	var app: ZenithStoreApp

	@ObservedObject private var _store = ZenithStoreManager.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			NavigationLink(destination: ZenithStoreDetailView(app: app)) {
				HStack(alignment: .top, spacing: 12) {
					ZenithStoreIconView(url: app.iconURL, size: 64)
					VStack(alignment: .leading, spacing: 3) {
						Text(app.name)
							.font(.headline)
							.lineLimit(2)
							// Two headline lines, always: a
							// one-line name must not shrink the
							// card, or the row goes uneven.
							.frame(minHeight: 44, alignment: .leading)
						Text(app.developerName ?? "مطوّر مو معروف")
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.lineLimit(1)
						Text("v\(app.version)")
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
					// Never squeeze the text vertically: a
					// horizontal scroll view measures its
					// children with a compressed height, which
					// cut the name off in 2.36. The text stack
					// keeps its real height here.
					.fixedSize(horizontal: false, vertical: true)
				}
				.contentShape(Rectangle())
			}
			.foregroundStyle(.primary)

			HStack {
				if _store.update(for: app.bundleIdentifier, installedVersion: nil) != nil {
					ZenithStoreUpdateBadge()
				}
				Spacer()
				ZenithStoreDownloadButton(app: app)
			}
		}
		.padding(14)
		.zenithGlassCard()
		.frame(width: 280)
	}
}

// MARK: - Game grid card
struct ZenithStoreGridCardView: View {
	var app: ZenithStoreApp

	@ObservedObject private var _store = ZenithStoreManager.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			NavigationLink(destination: ZenithStoreDetailView(app: app)) {
				HStack(alignment: .top, spacing: 10) {
					ZenithStoreIconView(url: app.iconURL, size: 56)
					VStack(alignment: .leading, spacing: 2) {
						Text(app.name)
							.font(.subheadline.bold())
							.lineLimit(2)
							// Two lines, always, so grid cards in
							// one row stay the same height.
							.frame(minHeight: 38, alignment: .leading)
						Text(app.developerName ?? "مطوّر مو معروف")
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
					// Never squeeze the text vertically inside
					// the grid — same 2.36 clipping cause as the
					// featured card.
					.fixedSize(horizontal: false, vertical: true)
				}
				.contentShape(Rectangle())
			}
			.foregroundStyle(.primary)

			HStack {
				Text("v\(app.version)")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				Spacer()
				if _store.update(for: app.bundleIdentifier, installedVersion: nil) != nil {
					ZenithStoreUpdateBadge()
				}
			}

			ZenithStoreDownloadButton(app: app, fullWidth: true)
		}
		.padding(12)
		.zenithGlassCard(cornerRadius: 14)
	}
}
