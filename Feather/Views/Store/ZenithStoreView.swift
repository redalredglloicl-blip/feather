//
//  ZenithStoreView.swift
//  Zenith
//
//  Zenith 2.34 (Store): the Store tab — a live store fed by the
//  community AltStore-source feeds through ZenithStoreManager:
//  real apps and games, real icons/versions/download links.
//  Search at the top, a paste-an-App-Store-link row, featured
//  apps, games, then apps. Pull-to-refresh calls refresh().
//  Starfield behind everything, like the other tabs.
//

import SwiftUI
import NukeUI

// MARK: - View
struct ZenithStoreView: View {
	@StateObject private var _store = ZenithStoreManager.shared

	@State private var _searchText = ""
	@State private var _linkText = ""
	@State private var _linkResult: ZenithStoreApp?
	@State private var _linkMessage: String?
	@State private var _isLookingUpLink = false

	var body: some View {
		NBNavigationView("المتجر") {
			ScrollView {
				VStack(alignment: .leading, spacing: 20) {
					_linkSection

					if let error = _store.errorMessage {
						_errorSection(error)
					}

					if _store.isLoading && _store.apps.isEmpty {
						ProgressView("جاي أجيب المتجر...")
							.frame(maxWidth: .infinity)
							.padding(.top, 40)
					} else if !_searchText.isEmpty {
						_searchResults
					} else {
						_catalogSections
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

	// MARK: - Paste an App Store link
	private var _linkSection: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("عندك رابط تطبيق من آب ستور؟")
				.font(.headline)

			HStack(spacing: 8) {
				TextField("الصق الرابط هنا...", text: $_linkText)
					.textFieldStyle(.roundedBorder)
					.autocapitalization(.none)
					.disableAutocorrection(true)

				Button {
					_lookUpLink()
				} label: {
					Text("جيب التطبيق")
						.fontWeight(.semibold)
						.foregroundStyle(.black)
						.padding(.horizontal, 14)
						.padding(.vertical, 8)
						.background(Color(hex: "#FFC778"), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
				}
				.buttonStyle(ZenithPressButtonStyle())
				.disabled(_linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || _isLookingUpLink)
			}

			if _isLookingUpLink {
				ProgressView("جاي أدور عليه...")
			}
			if let result = _linkResult {
				ZenithStoreRowView(app: result)
			}
			if let message = _linkMessage {
				Text(message)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
		}
		.padding(14)
		.zenithGlassCard()
	}

	private func _lookUpLink() {
		let text = _linkText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }
		_linkResult = nil
		_linkMessage = nil
		_isLookingUpLink = true
		_store.lookupAppStoreLink(text) { app, message in
			DispatchQueue.main.async {
				_isLookingUpLink = false
				_linkResult = app
				_linkMessage = message
			}
		}
	}

	// MARK: - Error banner
	private func _errorSection(_ message: String) -> some View {
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
				}
			}
		}
	}

	// MARK: - Catalog
	private var _catalogSections: some View {
		Group {
			if !_store.featured.isEmpty {
				_sectionTitle("مميّزة")
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 12) {
						ForEach(_store.featured, id: \.id) { app in
							ZenithStoreFeaturedCardView(app: app)
						}
					}
				}
			}

			if !_store.games.isEmpty {
				_sectionTitle("ألعاب")
				LazyVGrid(
					columns: [GridItem(.flexible()), GridItem(.flexible())],
					spacing: 12
				) {
					ForEach(_store.games, id: \.id) { app in
						ZenithStoreGridCardView(app: app)
					}
				}
			}

			if !_store.storeApps.isEmpty {
				_sectionTitle("تطبيقات")
				ForEach(_store.storeApps, id: \.id) { app in
					ZenithStoreRowView(app: app)
				}
			}

			if _store.apps.isEmpty {
				Text("المتجر فاضي هسه — اسحب لتحت حتى تحدّث")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .center)
					.padding(.top, 40)
			}
		}
	}

	private func _sectionTitle(_ title: String) -> some View {
		Text(title)
			.font(.title3.bold())
			.padding(.top, 4)
	}
}
