//
//  ZenithStoreManager.swift
//  Zenith
//
//  Zenith 2.34 (Store): fetches, merges and caches the Zenith Store
//  catalog from the live community AltStore-source feeds, and hands
//  downloads to the existing DownloadManager.
//
//  Feeds (all verified live):
//  * CyPwn IPA Library — apps + games, v1 flat format.
//  * SideStore Community (Team Picks) — emulators + tools, v1 flat
//    with a versions[] array.
//  * Quantum Source — emulators + tools, v2 versions[] format.
//
//  The app never pre-checks download links: a dead link fails
//  honestly inside the normal download flow (the Downloads tab
//  shows the failure), instead of the store silently hiding apps.
//  The catalog is cached to disk, so the store still opens from
//  the last good fetch when the internet is gone.

import CoreData
import Foundation

@MainActor
final class ZenithStoreManager: ObservableObject {
	static let shared = ZenithStoreManager()

	@Published private(set) var apps: [ZenithStoreApp] = []
	@Published private(set) var isLoading = false
	@Published private(set) var errorMessage: String?
	@Published private(set) var lastUpdated: Date?
	@Published private(set) var usingCachedCatalog = false

	private static let _cacheFileName = "ZenithStoreCatalog.json"

	private static let _feeds: [(name: String, url: String)] = [
		(name: "CyPwn", url: "https://ipa.cypwn.xyz/cypwn.json"),
		(name: "SideStore", url: "https://community-apps.sidestore.io/sidecommunity.json"),
		(name: "Quantum", url: "https://quarksources.github.io/quantumsource.json")
	]

	private static let _cacheFileURL: URL? = FileManager.default
		.urls(for: .cachesDirectory, in: .userDomainMask).first?
		.appendingPathComponent(_cacheFileName)

	private lazy var _session: URLSession = {
		let config = URLSessionConfiguration.default
		config.timeoutIntervalForRequest = 25
		config.timeoutIntervalForResource = 25
		config.httpAdditionalHeaders = [
			"User-Agent": DownloadManager.browserUserAgent
		]
		return URLSession(configuration: config)
	}()

	// MARK: - Derived lists

	// First 8 apps that have screenshots (the showcase row); falls
	// back to the first 8 apps when none have screenshots yet.
	var featured: [ZenithStoreApp] {
		let withScreenshots = apps.filter { !$0.screenshotURLs.isEmpty }
		return Array((withScreenshots.isEmpty ? apps : withScreenshots).prefix(8))
	}

	var games: [ZenithStoreApp] {
		apps.filter { $0.isGame }
	}

	var storeApps: [ZenithStoreApp] {
		apps.filter { !$0.isGame }
	}

	func searchResults(for query: String) -> [ZenithStoreApp] {
		let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return apps }
		let needle = text.lowercased()
		return apps.filter { app in
			app.name.lowercased().contains(needle)
				|| (app.developerName?.lowercased().contains(needle) ?? false)
		}
	}

	// MARK: - Refresh

	func refresh() async {
		guard !isLoading else { return }
		isLoading = true
		defer { isLoading = false }

		let fetched = await _fetchAllFeeds()
		let merged = Self._merge(fetched)
		guard !merged.isEmpty else {
			// Total failure: fall back to the saved catalog.
			if let cached = _loadCachedCatalog() {
				apps = cached
				usingCachedCatalog = true
				errorMessage = "ما گدرت أحدث المتجر، هاي نسخة محفوظة قديمة"
			} else {
				usingCachedCatalog = false
				errorMessage = "ما گدرت أوصل للمتجر، تحقق من النت وحاول مرة ثانية"
			}
			return
		}

		apps = merged
		lastUpdated = Date()
		usingCachedCatalog = false
		errorMessage = nil
		_saveCachedCatalog(merged)
	}

	// All three feeds in parallel; a failed feed just contributes
	// nothing, it never blocks the other two.
	private func _fetchAllFeeds() async -> [(name: String, apps: [ZenithStoreApp])] {
		await withTaskGroup(of: (name: String, apps: [ZenithStoreApp]).self) { group in
			for feed in Self._feeds {
				group.addTask {
					guard let url = URL(string: feed.url) else {
						return (name: feed.name, apps: [])
					}
					do {
						let (data, response) = try await self._session.data(from: url)
						guard (response as? HTTPURLResponse)?.statusCode == 200 else {
							return (name: feed.name, apps: [])
						}
						let parsed = try JSONDecoder().decode(ZenithStoreFeed.self, from: data)
						let tagged = parsed.apps.map { app in
							var taggedApp = app
							taggedApp.sourceName = feed.name
							return taggedApp
						}
						return (name: feed.name, apps: tagged)
					} catch {
						return (name: feed.name, apps: [])
					}
				}
			}
			var results: [(name: String, apps: [ZenithStoreApp])] = []
			for await result in group {
				results.append(result)
			}
			return results
		}
	}

	// One entry per bundle ID; when two feeds list the same app,
	// the one with the newest version date wins.
	private static func _merge(
		_ feeds: [(name: String, apps: [ZenithStoreApp])]
	) -> [ZenithStoreApp] {
		var byBundleID: [String: ZenithStoreApp] = [:]
		for feed in feeds {
			for app in feed.apps where app.downloadURL != nil {
				guard let existing = byBundleID[app.bundleIdentifier] else {
					byBundleID[app.bundleIdentifier] = app
					continue
				}
				switch (existing.versionDateParsed, app.versionDateParsed) {
				case (nil, _?):
					byBundleID[app.bundleIdentifier] = app
				case let (old?, new?) where new > old:
					byBundleID[app.bundleIdentifier] = app
				default:
					break
				}
			}
		}
		return byBundleID.values.sorted {
			$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
		}
	}

	// MARK: - Cache

	private func _saveCachedCatalog(_ catalog: [ZenithStoreApp]) {
		guard let url = Self._cacheFileURL else { return }
		guard let data = try? JSONEncoder().encode(catalog) else { return }
		try? data.write(to: url, options: .atomic)
	}

	private func _loadCachedCatalog() -> [ZenithStoreApp]? {
		guard let url = Self._cacheFileURL,
			  let data = try? Data(contentsOf: url) else {
			return nil
		}
		return try? JSONDecoder().decode([ZenithStoreApp].self, from: data)
	}

	// MARK: - Download

	// Hands the IPA to the existing download machinery: the
	// Downloads tab shows live progress, and a finished IPA flows
	// through Zenith.handlePackageFile into the Library and the
	// sign flow automatically. Returns nil when the app has no
	// download link at all (a feed entry should never reach here
	// without one — _merge already filters those out).
	@discardableResult
	func download(_ app: ZenithStoreApp) -> Download? {
		guard let url = app.downloadURL else { return nil }
		return DownloadManager.shared.startDownload(from: url, id: app.bundleIdentifier)
	}

	// MARK: - Updates for installed apps

	// The feed entry for this bundle ID, but only when its version
	// is newer than the installed one. Nil means up to date, not
	// in the store, or the installed version is unknown.
	func update(for bundleIdentifier: String, installedVersion: String?) -> ZenithStoreApp? {
		guard let installedVersion, !installedVersion.isEmpty else { return nil }
		guard let feedApp = apps.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
			return nil
		}
		guard ZenithStoreVersion.isNewer(feedApp.version, than: installedVersion) else {
			return nil
		}
		return feedApp
	}

	// Every installed app that has a newer version in the store.
	func installedUpdates() -> [(bundleIdentifier: String, feedApp: ZenithStoreApp)] {
		let request = Signed.fetchRequest()
		let installed = (try? Storage.shared.context.fetch(request)) ?? []
		var updates: [(bundleIdentifier: String, feedApp: ZenithStoreApp)] = []
		for app in installed {
			guard let identifier = app.identifier, !identifier.isEmpty else { continue }
			guard let feedApp = update(for: identifier, installedVersion: app.version) else {
				continue
			}
			updates.append((bundleIdentifier: identifier, feedApp: feedApp))
		}
		return updates
	}

	// MARK: - App Store link lookup

	// The user pastes an App Store link; the iTunes Search API
	// (no login) resolves it to a bundle ID, and the store is
	// searched for that bundle ID. Either the matching store app
	// or a plain Iraqi message comes back — never both.
	func lookupAppStoreLink(_ text: String, completion: @escaping (ZenithStoreApp?, String?) -> Void) {
		guard let appID = Self._appStoreID(from: text) else {
			completion(nil, "هذا الرابط مو رابط متجر، انسخ رابط التطبيق من متجر أبل وحاول مرة ثانية")
			return
		}
		guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(appID)") else {
			completion(nil, "ما لگيت هالتطبيق بالمتجر")
			return
		}
		URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
			guard let self else {
				DispatchQueue.main.async {
					completion(nil, "ما لگيت هالتطبيق بالمتجر")
				}
				return
			}
			let bundleID = Self._bundleID(fromLookupData: data)
			let found = bundleID.flatMap { id in
				self.apps.first(where: { $0.bundleIdentifier == id })
			}
			DispatchQueue.main.async {
				if let found {
					completion(found, nil)
				} else {
					completion(nil, "ما لگيت هالتطبيق بالمتجر")
				}
			}
		}.resume()
	}

	// App Store links carry the numeric ID as ".../id123456789"
	// or "?id=123456789" (sometimes "&id=").
	private static func _appStoreID(from text: String) -> String? {
		let patterns = ["id(\\d+)", "[?&]id=(\\d+)"]
		for pattern in patterns {
			guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
			let range = NSRange(text.startIndex..., in: text)
			if let match = regex.firstMatch(in: text, range: range),
			   let idRange = Range(match.range(at: 1), in: text) {
				return String(text[idRange])
			}
		}
		return nil
	}

	// iTunes lookup answer: {"resultCount":1,"results":[{"bundleId":"..."}]}.
	private static func _bundleID(fromLookupData data: Data?) -> String? {
		guard let data,
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let results = json["results"] as? [[String: Any]],
			  let first = results.first else {
			return nil
		}
		return first["bundleId"] as? String
	}
}
