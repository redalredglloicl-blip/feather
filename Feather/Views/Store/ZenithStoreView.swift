//
//  ZenithStoreView.swift
//  Zenith
//
//  Zenith 2.34 (Store): the Store tab — a live store fed by the
//  community AltStore-source feeds through ZenithStoreManager:
//  real apps and games, real icons/versions/download links.
//  Zenith 2.37: the paste-an-App-Store-link row is gone — search
//  only. The home is short: a featured row, then TWO big options
//  ("التطبيقات" / "الألعاب"), each opening its own screen with
//  its own search (ZenithStoreSections.swift). No more one long
//  scroll stacking games then apps. Pull-to-refresh calls
//  refresh(). Starfield behind everything, like the other tabs.
//

import SwiftUI
import NimbleViews
import NukeUI

// MARK: - View
struct ZenithStoreView: View {
	@StateObject private var _store = ZenithStoreManager.shared

	@State private var _searchText = ""

	var body: some View {
		NBNavigationView("المتجر") {
			ScrollView {
				VStack(alignment: .leading, spacing: 20) {
					if let error = _store.errorMessage {
						ZenithStoreErrorBannerView(message: error)
					}

					if _store.isLoading && _store.apps.isEmpty {
						ProgressView("جاي أجيب المتجر...")
							.frame(maxWidth: .infinity)
							.padding(.top, 40)
					} else if !_searchText.isEmpty {
						_searchResults
					} else if _store.apps.isEmpty {
						Text("المتجر فاضي هسه — اسحب لتحت حتى تحدّث")
							.foregroundStyle(.secondary)
							.frame(maxWidth: .infinity, alignment: .center)
							.padding(.top, 40)
					} else {
						_featuredSection
						_sectionOptions
					}

					if _store.usingCachedCatalog {
						Text(_cachedNote)
							.font(.caption)
							.foregroundStyle(.secondary)
							.frame(maxWidth: .infinity, alignment: .center)
					}
				}
				.padding()
			}
			.refreshable {
				await _store.refresh()
			}
			.searchable(text: $_searchText, prompt: "دوّر على تطبيق أو لعبة...")
			.starfieldBackground()
			.onAppear {
				if _store.apps.isEmpty && !_store.isLoading {
					Task { await _store.refresh() }
				}
			}
		}
	}

	// MARK: - Cached note
	private var _cachedNote: String {
		if let lastUpdated = _store.lastUpdated {
			return "نسخة محفوظة من \(ZenithStoreFormatters.date(lastUpdated)) — يمكن مو أحدث شي، اسحب لتحت حتى تحدّث"
		}
		return "نسخة محفوظة — يمكن مو أحدث شي، اسحب لتحت حتى تحدّث"
	}

	// MARK: - Search results
	private var _searchResults: some View {
		let results = _store.searchResults(for: _searchText)
		return Group {
			if results.isEmpty {
				Text("ما لگيت شي بهالاسم")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .center)
					.padding(.top, 40)
			} else {
				ForEach(results, id: \.id) { app in
					ZenithStoreRowView(app: app)
					Divider()
				}
			}
		}
	}

	// MARK: - Featured
	private var _featuredSection: some View {
		Group {
			if !_store.featured.isEmpty {
				_sectionTitle("مميّزة")
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(alignment: .top, spacing: 12) {
						ForEach(_store.featured, id: \.id) { app in
							ZenithStoreFeaturedCardView(app: app)
						}
					}
					.padding(.vertical, 2)
				}
			}
		}
	}

	// MARK: - The two options
	/// Two big tappable cards — "التطبيقات" and "الألعاب" — each
	/// opens its own screen with its own search inside it. The
	/// home itself stays short: no stacked games-then-apps scroll.
	private var _sectionOptions: some View {
		VStack(spacing: 14) {
			NavigationLink(destination: ZenithStoreAppsView()) {
				_optionCard(
					title: "التطبيقات",
					subtitle: "\(_store.storeApps.count) تطبيق — دوّر وحمّل"
				)
			}
			.buttonStyle(ZenithPressButtonStyle())

			NavigationLink(destination: ZenithStoreGamesView()) {
				_optionCard(
					title: "الألعاب",
					subtitle: "\(_store.games.count) لعبة — دوّر وحمّل"
				)
			}
			.buttonStyle(ZenithPressButtonStyle())
		}
	}

	private func _optionCard(title: String, subtitle: String) -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(title)
					.font(.title3.bold())
					.foregroundStyle(.primary)
				Text(subtitle)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Text("شوف الكل")
				.font(.subheadline.bold())
				.foregroundStyle(Color(hex: "#FFC778"))
		}
		.padding(18)
		.frame(maxWidth: .infinity, alignment: .leading)
		.zenithGlassCard(cornerRadius: 18)
	}

	private func _sectionTitle(_ title: String) -> some View {
		Text(title)
			.font(.title3.bold())
			.padding(.top, 4)
	}
}
