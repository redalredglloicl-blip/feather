//
//  ZenithStoreManager.swift
//  Zenith
//
//  Zenith 2.37 (Store): fetches, merges and caches the Zenith Store
//  catalog from the live AltStore-source feeds, and hands downloads
//  to the existing DownloadManager.
//
//  Feeds (all verified live 2026-11-28, official/developer feeds
//  first, aggregators after):
//  * AltStore official — Delta, Clip.
//  * OatmealDome — DolphiniOS.
//  * Provenance — Provenance, iFly, iCube.
//  * Emily's Apps — developer source.
//  * UTM official — UTM, UTM SE.
//  * PokeMMO — PokeMMO.
//  * iSH — iSH (version "Build 813").
//  * CyPwn IPA Library — apps + games, v1 flat format.
//  * SideStore Community (Team Picks) — emulators + tools, v1 flat
//    with a versions[] array.
//  * Quantum Source — emulators + tools, v2 versions[] format.
//  * WuXu's Library++ — tweaked apps, incl. TikTok++.
//  * Quantum++ — tweaked apps, incl. the only WhatsApp++ copy.
//
//  Game/app classification comes from a batched iTunes Search
//  lookup (primaryGenreName == "Games" means game), cached to
//  disk per bundle ID; while an app has no looked-up genre yet,
//  the keyword heuristic on the model is the fallback.
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
	// App Store genre per bundle ID, from the iTunes lookup
	// (see _refreshGenres). Published so the Games/Apps split
	// redraws as genres arrive.
	@Published private(set) var genreByBundleID: [String: String] = [:]

	private static let _cacheFileName = "ZenithStoreCatalog.json"
	private static let _genreCacheFileName = "ZenithStoreGenres.json"

	// One iTunes lookup request carries this many bundle IDs
	// (comma-separated); 274 apps need 6 requests.
	private static let _genreBatchSize = 50

	// Official/developer feeds FIRST, aggregators after. Parse
	// order is the final tie-break in _merge; the version/date
	// rules decide before it ever matters.
	private static let _feeds: [(name: String, url: String)] = [
		(name: "AltStore", url: "https://cdn.altstore.io/file/altstore/apps.json"),
		(name: "OatmealDome", url: "https://altstore.oatmealdome.me/"),
		(name: "Provenance", url: "https://provenance-emu.com/apps.json"),
		(name: "Emily", url: "https://git.emilyh.de/Emily/AltStoreSource/raw/branch/main/apps.json"),
		(name: "UTM", url: "https://alt.getutm.app"),
		(name: "PokeMMO", url: "https://pokemmo.com/altstore/"),
		(name: "iSH", url: "https://ish.app/altstore.json"),
		(name: "CyPwn", url: "https://ipa.cypwn.xyz/cypwn.json"),
		(name: "SideStore", url: "https://community-apps.sidestore.io/sidecommunity.json"),
		(name: "Quantum", url: "https://quarksources.github.io/quantumsource.json"),
		(name: "WuXu", url: "https://wuxu1.github.io/wuxu-complete-plus.json"),
		(name: "Quantum++", url: "https://quarksources.github.io/quantumsource++.json")
	]

	private static let _cacheFileURL: URL? = FileManager.default
		.urls(for: .cachesDirectory, in: .userDomainMask).first?
		.appendingPathComponent(_cacheFileName)

	// App Store genre per bundle ID ("Games", "Entertainment",
	// ...), loaded from disk at launch so the Games/Apps split
	// is already right before any network call.
	private static let _genreCacheFileURL: URL? = FileManager.default
		.urls(for: .cachesDirectory, in: .userDomainMask).first?
		.appendingPathComponent(_genreCacheFileName)

	private lazy var _session: URLSession = {
		let config = URLSessionConfiguration.default
		config.timeoutIntervalForRequest = 25
		config.timeoutIntervalForResource = 25
		config.httpAdditionalHeaders = [
			"User-Agent": DownloadManager.browserUserAgent
		]
		return URLSession(configuration: config)
	}()

	private var _genreRefreshRunning = false

	// The genre cache is read from disk here, so the last known
	// Games/Apps split applies the moment the catalog loads —
	// before any lookup runs.
	init() {
		genreByBundleID = Self._loadGenreCache()
	}

	// MARK: - Derived lists

	// First 8 apps that have screenshots (the showcase row); falls
	// back to the first 8 apps when none have screenshots yet.
	var featured: [ZenithStoreApp] {
		let withScreenshots = apps.filter { !$0.screenshotURLs.isEmpty }
		return Array((withScreenshots.isEmpty ? apps : withScreenshots).prefix(8))
	}

	// Game or app? The looked-up App Store genre decides when
	// it is known: primaryGenreName == "Games" means game, any
	// other genre means app. While an app has no looked-up genre
	// yet, the keyword heuristic on the model is the fallback —
	// so the Games section is never empty and never waits on
	// the network.
	func isGame(_ app: ZenithStoreApp) -> Bool {
		if let genre = genreByBundleID[app.bundleIdentifier] {
			return genre == "Games"
		}
		return app.isGame
	}

	// games and storeApps partition the catalog exactly: every
	// app is in one of them, none in both, none in neither.
	var games: [ZenithStoreApp] {
		apps.filter { isGame($0) }
	}

	var storeApps: [ZenithStoreApp] {
		apps.filter { !isGame($0) }
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
				_scheduleGenreRefresh()
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
		_scheduleGenreRefresh()
	}

	// All twelve feeds in parallel; a failed feed just
	// contributes nothing, it never blocks the others.
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

	// One entry per bundle ID. When two feeds list the same app,
	// the one with the NEWEST version wins (numeric compare);
	// on a version tie, the one with the newer version date
	// wins. Parse order only breaks a full tie, which is why
	// the official feeds come first in _feeds.
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
				if Self._shouldReplace(existing: existing, with: app) {
					byBundleID[app.bundleIdentifier] = app
				}
			}
		}
		return byBundleID.values.sorted {
			$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
		}
	}

	// True when `candidate` should replace `existing` for the
	// same bundle ID.
	private static func _shouldReplace(
		existing: ZenithStoreApp,
		with candidate: ZenithStoreApp
	) -> Bool {
		// Both versions numeric: the newest version wins, and
		// an older version never replaces a newer one, whatever
		// the dates say (Ignited 1.8.6 beats 1.8.5, OldOS 2.0.7
		// beats 1.0, UTM 5.0.9 beats 4.3.5).
		if Self._isNumericVersion(existing.version),
		   Self._isNumericVersion(candidate.version) {
			if ZenithStoreVersion.isNewer(candidate.version, than: existing.version) {
				return true
			}
			if ZenithStoreVersion.isNewer(existing.version, than: candidate.version) {
				return false
			}
			// Same version: fall through to the date below.
		}
		// Either version is not numeric at all ("Build 813"),
		// or the versions tie: the newer version date decides.
		// That is what keeps iSH "Build 813" (2026-08-22) over
		// the stale "1.3.2" (2023-05-20) — a numeric compare
		// would wrongly call 1.3.2 newer than "Build 813".
		switch (existing.versionDateParsed, candidate.versionDateParsed) {
		case (nil, _?):
			return true
		case let (old?, new?) where new > old:
			return true
		default:
			return false
		}
	}

	// A version the numeric compare can actually judge: it
	// starts with a digit ("5.0.9", "1.3.2"). "Build 813" does
	// not, so it is never "newer" or "older" numerically — its
	// date decides instead.
	private static func _isNumericVersion(_ version: String) -> Bool {
		version.first?.isNumber ?? false
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

	// MARK: - Games classification (iTunes genre lookup)

	// Fire-and-forget: the lookup runs after the store already
	// shows, with the cached genres applied on launch. The
	// Games/Apps split redraws as genres arrive.
	private func _scheduleGenreRefresh() {
		Task { await _refreshGenres() }
	}

	// Looks up the App Store genre for every catalog app that
	// has no cached genre yet, in batches of _genreBatchSize
	// bundle IDs per request (the lookup endpoint takes several
	// IDs in one call, comma-separated, no login, no Apple ID).
	// Runs in the background and never blocks the store UI: a
	// failed batch just keeps the heuristic fallback for those
	// apps, so the store keeps working with no internet or an
	// API error. Genres are saved after every batch, so a kill
	// mid-refresh keeps what already arrived.
	private func _refreshGenres() async {
		guard !_genreRefreshRunning else { return }
		_genreRefreshRunning = true
		defer { _genreRefreshRunning = false }

		let uncached = apps
			.map { $0.bundleIdentifier }
			.filter { genreByBundleID[$0] == nil }
			.sorted()
		guard !uncached.isEmpty else { return }

		var updated = genreByBundleID
		for start in stride(from: 0, to: uncached.count, by: Self._genreBatchSize) {
			let end = min(start + Self._genreBatchSize, uncached.count)
			let chunk = Array(uncached[start..<end])
			let joined = chunk.joined(separator: ",")
			guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(joined)&country=US&limit=200") else {
				continue
			}
			guard let (data, response) = try? await _session.data(from: url),
				  (response as? HTTPURLResponse)?.statusCode == 200 else {
				continue
			}
			let found = Self._genres(fromLookupData: data)
			for (bundleID, genre) in found {
				updated[bundleID] = genre
			}
			genreByBundleID = updated
			Self._saveGenreCache(updated)
		}
	}

	// iTunes lookup answer:
	// {"resultCount":N,"results":[{"bundleId":"...","primaryGenreName":"Games"}]}.
	// Apps the App Store never carried simply do not appear in
	// results — they keep the heuristic fallback.
	private static func _genres(fromLookupData data: Data) -> [String: String] {
		guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let results = json["results"] as? [[String: Any]] else {
			return [:]
		}
		var genres: [String: String] = [:]
		for result in results {
			guard let bundleID = result["bundleId"] as? String,
				  let genre = result["primaryGenreName"] as? String,
				  !bundleID.isEmpty, !genre.isEmpty else {
				continue
			}
			genres[bundleID] = genre
		}
		return genres
	}

	// The genre cache lives in Caches, next to the catalog
	// cache, and survives app restarts — a genre is fetched
	// once, not on every open.
	private static func _saveGenreCache(_ genres: [String: String]) {
		guard let url = Self._genreCacheFileURL else { return }
		guard let data = try? JSONEncoder().encode(genres) else { return }
		try? data.write(to: url, options: .atomic)
	}

	private static func _loadGenreCache() -> [String: String] {
		guard let url = Self._genreCacheFileURL,
			  let data = try? Data(contentsOf: url) else {
			return [:]
		}
		let decoded = try? JSONDecoder().decode([String: String].self, from: data)
		return decoded ?? [:]
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
