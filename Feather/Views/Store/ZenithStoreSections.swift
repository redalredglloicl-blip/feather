//
//  ZenithStoreSections.swift
//  Zenith
//
//  Zenith 2.37 (Store): the two Store sections, each its own
//  screen with its own search — "التطبيقات" (rows) and "الألعاب"
//  (2-column grid). Both are pushed from the Store home inside
//  the store's own NavigationStack, so neither builds its own
//  NBNavigationView (same pattern as ZenithStoreDetailView).
//  Search filters only that section's list, through the
//  manager's existing searchResults(for:) — nothing new is
//  fetched here. Error banner + retry, pull-to-refresh and the
//  empty-search message are shared with the Store home.
//

import SwiftUI

// MARK: - Apps section
struct ZenithStoreAppsView: View {
	@ObservedObject private var _store = ZenithStoreManager.shared

	@State private var _searchText = ""

	/// The manager's search, narrowed to non-games only. An empty
	/// query returns the whole catalog, so this is the full apps
	/// list until the user starts typing.
	private var _apps: [ZenithStoreApp] {
		_store.searchResults(for: _searchText).filter { !$0.isGame }
	}

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				if let error = _store.errorMessage {
					ZenithStoreErrorBannerView(message: error)
						.padding(.bottom, 12)
				}

				if _store.isLoading && _store.apps.isEmpty {
					ProgressView("جاي أجيب التطبيقات...")
						.frame(maxWidth: .infinity)
						.padding(.top, 40)
				} else if _apps.isEmpty {
					Text(_emptyMessage)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .center)
						.padding(.top, 40)
				} else {
					ForEach(_apps, id: \.id) { app in
						ZenithStoreRowView(app: app)
							.padding(.vertical, 4)
						Divider()
					}
				}
			}
			.padding()
		}
		.starfieldBackground()
		.navigationTitle("التطبيقات")
		.searchable(text: $_searchText, prompt: "دوّر على تطبيق...")
		.refreshable {
			await _store.refresh()
		}
		.onAppear {
			if _store.apps.isEmpty && !_store.isLoading {
				Task { await _store.refresh() }
			}
		}
	}

	private var _emptyMessage: String {
		if !_searchText.isEmpty {
			return "ما لگيت تطبيق بهالاسم"
		}
		return "ما عندنا تطبيقات هسه — اسحب لتحت حتى تحدّث"
	}
}

// MARK: - Games section
struct ZenithStoreGamesView: View {
	@ObservedObject private var _store = ZenithStoreManager.shared

	@State private var _searchText = ""

	/// The manager's search, narrowed to games only.
	private var _games: [ZenithStoreApp] {
		_store.searchResults(for: _searchText).filter { $0.isGame }
	}

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 12) {
				if let error = _store.errorMessage {
					ZenithStoreErrorBannerView(message: error)
				}

				if _store.isLoading && _store.apps.isEmpty {
					ProgressView("جاي أجيب الألعاب...")
						.frame(maxWidth: .infinity)
						.padding(.top, 40)
				} else if _games.isEmpty {
					Text(_emptyMessage)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .center)
						.padding(.top, 40)
				} else {
					LazyVGrid(
						columns: [GridItem(.flexible()), GridItem(.flexible())],
						spacing: 12
					) {
						ForEach(_games, id: \.id) { app in
							ZenithStoreGridCardView(app: app)
						}
					}
				}
			}
			.padding()
		}
		.starfieldBackground()
		.navigationTitle("الألعاب")
		.searchable(text: $_searchText, prompt: "دوّر على لعبة...")
		.refreshable {
			await _store.refresh()
		}
		.onAppear {
			if _store.apps.isEmpty && !_store.isLoading {
				Task { await _store.refresh() }
			}
		}
	}

	private var _emptyMessage: String {
		if !_searchText.isEmpty {
			return "ما لگيت لعبة بهالاسم"
		}
		return "ما عندنا ألعاب هسه — اسحب لتحت حتى تحدّث"
	}
}
