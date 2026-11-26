
//
//  ForcedUpdateManager.swift
//  Zenith
//
//  Zenith forced update + anti-tamper (v2, Phase 5).
//
//  On every launch the app asks Reda's Firebase (the same project as
//  Rio) for the minimum required build and the kill switch:
//      /feather-app/minVersion   — an INTEGER, e.g. 2
//      /feather-app/killed       — true blocks the app regardless of version
//      /feather-app/updateURL    — link for the "حدّث هسه" button
//  Plain HTTPS GETs to the RTDB REST endpoints, no Firebase SDK.
//
//  Why a build NUMBER, not a version string: the installed v1 reports
//  marketing version 2.9.0 while v2 reports 2.0, so no version string
//  can tell them apart ("2.0" never blocks v1; "2.9.1" would block v2
//  itself). Build numbers are plain monotonic integers instead:
//  v2 is build 2, the next update is build 3, and so on. The number
//  lives in the app as the ZenithBuildNumber Info.plist key. The
//  display version ("2.0", shown in Settings) is display-only and
//  plays no part in this check.
//
//  Rules (all intentional):
//  * Blocked only when the server POSITIVELY says so: killed == true,
//    or minVersion is set and the installed build number is smaller.
//  * Values absent (not set yet) -> no enforcement, app opens normally.
//  * Check fails (offline) -> fall back to the last cached values.
//    A cached minVersion saying this build is old STAYS blocked; only
//    with no cached value at all does the app fail open. The block
//    screen never appears on a failed check alone.
//  * Signing and installing refuse to run unless a fresh check has
//    passed (in-memory flag, set only by a real check that found no
//    block). A failed check with no cached values leaves the flag
//    unset, so signing/installing refuse until a live check succeeds.
//    The gate re-runs the check on demand, so a transient failure
//    only delays the action until the network is back.
//
//  Honest limits: this is a server-side gate, not a vault. A
//  determined attacker with a decrypted IPA can patch the check out
//  of the binary and re-sign it. What the gate DOES do: it cannot be
//  bypassed by blocking the network (a failed check refuses signing
//  instead of allowing it), and it cannot be bypassed by editing the
//  app's stored data (the pass flag lives only in memory; the minimum
//  version comes from the server, not the device).

import Foundation
import SwiftUI

enum ForcedUpdateError: Error, LocalizedError {
	case updateRequired
	case checkFailed
	
	var errorDescription: String? {
		switch self {
		case .updateRequired:
			return .localized("حدّث Zenith أولاً.")
		case .checkFailed:
			return .localized("ما قدرت أتأكد من إصدار التطبيق. تأكد من النت وحاول مرة ثانية.")
		}
	}
}

@MainActor
final class ForcedUpdateManager: ObservableObject {
	static let shared = ForcedUpdateManager()
	
	// MARK: - Remote config
	
	private static let baseURL = "https://spychat-4f8d5-default-rtdb.firebaseio.com/feather-app"
	private static var minVersionURL: URL { URL(string: "\(baseURL)/minVersion.json")! }
	private static var killedURL: URL { URL(string: "\(baseURL)/killed.json")! }
	private static var updateURLValue: URL { URL(string: "\(baseURL)/updateURL.json")! }
	private static var latestVersionNameURL: URL { URL(string: "\(baseURL)/latestVersionName.json")! }
	
	// MARK: - Cache (UserDefaults)
	
	private static let cachedMinVersionKey = "Zenith.cachedMinVersion"
	private static let cachedKilledKey = "Zenith.cachedKilled"
	private static let cachedUpdateURLKey = "Zenith.cachedUpdateURL"
	private static let cachedLatestVersionNameKey = "Zenith.cachedLatestVersionName"
	
	// MARK: - Published state
	
	/// True when the server (or the cache, on a failed check) says
	/// this build must update. While true the whole app is replaced
	/// by the blocking update screen.
	@Published private(set) var isUpdateRequired = false
	/// Where the update button goes, when known.
	@Published private(set) var updateURL: URL?
	/// The new version's display name (e.g. "2.3") from
	/// /feather-app/latestVersionName, when the server knows it.
	/// Nil when the field is absent — the block screen then shows
	/// plain "Zenith" as before.
	@Published private(set) var latestVersionName: String?
	@Published private(set) var isChecking = false
	
	/// Set ONLY by a real check that completed and found no block
	/// (fresh values, or cached values saying the app is fine).
	/// Lives in memory only — a relaunch must check again.
	private(set) var hasPassedCheck = false
	
	private var _checkTask: Task<Void, Never>?
	
	private let _session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 15
		config.timeoutIntervalForResource = 20
		return URLSession(configuration: config)
	}()
	
	private init() {
		// The cached version name (if any) shows from the first frame.
		latestVersionName = Self.cachedLatestVersionName
		// If a previous run already learned this build is old, stay
		// blocked from the very first frame — the network check below
		// can only lift the block, never delay it.
		if let cached = Self.cachedMinVersion,
		   Self.installedBuildNumber < cached {
			isUpdateRequired = true
			updateURL = Self.cachedUpdateURL
		} else if Self.cachedKilled {
			isUpdateRequired = true
			updateURL = Self.cachedUpdateURL
		}
	}
	
	// MARK: - Installed build number
	
	/// The ZenithBuildNumber Info.plist key (an integer: v2 is 2).
	/// A build without the key reads as 0 — older than any minVersion
	/// of 1 or more, which is the safe direction. Accepts an integer
	/// or a numeric string, because a build-setting value (INFOPLIST_KEY)
	/// arrives as a string while the plist file stores an integer.
	/// Read directly — NEVER CFBundleVersion: the build workflow
	/// sets that to the git commit SHA, not a number. The marketing
	/// version (CFBundleShortVersionString, e.g. "2.0") is display-only
	/// and is never compared here: v1 reports 2.9.0, v2 reports 2.0.
	static var installedBuildNumber: Int {
		let value = Bundle.main.object(forInfoDictionaryKey: "ZenithBuildNumber")
		if let number = value as? NSNumber {
			return number.intValue
		}
		if let string = value as? String {
			return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
		}
		return 0
	}
	
	// MARK: - Check
	
	/// Runs the remote check and applies the result. Safe to call on
	/// every launch and on every foreground return. Concurrent callers
	/// share the same in-flight check instead of starting another.
	func checkForUpdate() async {
		if let inFlight = _checkTask {
			await inFlight.value
			return
		}
		let task = Task { await _performCheck() }
		_checkTask = task
		await task.value
		_checkTask = nil
	}
	
	/// Returns true only when a check has passed. Runs the check on
	/// demand when it has not passed yet. Used by the signing and
	/// installing gates — the flag is set only by a real check.
	func ensureCheckPassed() async -> Bool {
		if hasPassedCheck {
			return true
		}
		await checkForUpdate()
		return hasPassedCheck
	}
	
	// MARK: - Private
	
	private func _performCheck() async {
		guard !isChecking else { return }
		isChecking = true
		defer { isChecking = false }
		
		async let minVersionFetch = _tryFetchInt(from: Self.minVersionURL)
		async let killedFetch = _tryFetchBool(from: Self.killedURL)
		async let updateURLFetch = _tryFetchString(from: Self.updateURLValue)
		async let nameFetch = _tryFetchString(from: Self.latestVersionNameURL)
		let minVersionResult = await minVersionFetch
		let killedResult = await killedFetch
		let updateURLResult = await updateURLFetch
		let nameResult = await nameFetch
		
		let fetchedAny = minVersionResult.succeeded || killedResult.succeeded || updateURLResult.succeeded || nameResult.succeeded
		
		if fetchedAny {
			// Fresh values win. A successful fetch that returned null
			// means the value is absent — clear the matching cache so
			// removing a value from Firebase lifts the enforcement.
			if minVersionResult.succeeded {
				if let value = minVersionResult.value {
					UserDefaults.standard.set(value, forKey: Self.cachedMinVersionKey)
				} else {
					UserDefaults.standard.removeObject(forKey: Self.cachedMinVersionKey)
				}
			}
			if killedResult.succeeded {
				UserDefaults.standard.set(killedResult.value ?? false, forKey: Self.cachedKilledKey)
			}
			if updateURLResult.succeeded {
				if let value = updateURLResult.value {
					UserDefaults.standard.set(value, forKey: Self.cachedUpdateURLKey)
				} else {
					UserDefaults.standard.removeObject(forKey: Self.cachedUpdateURLKey)
				}
			}
			if nameResult.succeeded {
				if let value = nameResult.value {
					UserDefaults.standard.set(value, forKey: Self.cachedLatestVersionNameKey)
				} else {
					UserDefaults.standard.removeObject(forKey: Self.cachedLatestVersionNameKey)
				}
			}
			_apply(
				minVersion: minVersionResult.value,
				killed: killedResult.value ?? false,
				updateURLString: updateURLResult.value,
				latestVersionName: nameResult.value
			)
		} else {
			// All fetches failed (offline): fall back to the cache.
			// Only with no cached value at all do we fail open.
			_apply(
				minVersion: Self.cachedMinVersion,
				killed: Self.cachedKilled,
				updateURLString: Self.cachedUpdateURLString,
				latestVersionName: Self.cachedLatestVersionName,
				fromCache: true
			)
		}
	}
	
	/// Decides blocked / passed from a set of values (fresh or cached).
	private func _apply(minVersion: Int?, killed: Bool, updateURLString: String?, latestVersionName: String?, fromCache: Bool = false) {
		let tooOld = minVersion.map { Self.installedBuildNumber < $0 } ?? false
		let blocked = killed || tooOld
		
		self.latestVersionName = latestVersionName
		if let urlString = updateURLString, let url = URL(string: urlString) {
			updateURL = url
		} else {
			updateURL = nil
		}
		
		if blocked {
			isUpdateRequired = true
			hasPassedCheck = false
		} else {
			isUpdateRequired = false
			// A fresh successful check passes. A failed check only
			// passes when we already had cached values saying the app
			// is fine — with no cached value at all the flag stays
			// unset and signing/installing refuse until a live check
			// succeeds.
			hasPassedCheck = !fromCache || _hasAnyCachedValue
		}
	}
	
	private var _hasAnyCachedValue: Bool {
		Self.cachedMinVersion != nil || Self.cachedKilled || Self.cachedUpdateURLString != nil
	}
	
	// MARK: - Cache accessors
	
	/// Defensive read: the cache now stores an Int, but a stale
	/// STRING from the earlier string-based v2 build must not crash
	/// the read — a non-numeric value is ignored (treated as absent).
	/// A stale numeric string is honoured as that build number.
	private static var cachedMinVersion: Int? {
		let value = UserDefaults.standard.object(forKey: cachedMinVersionKey)
		if let number = value as? NSNumber {
			return number.intValue
		}
		if let string = value as? String {
			return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
		}
		return nil
	}
	
	private static var cachedKilled: Bool {
		UserDefaults.standard.bool(forKey: cachedKilledKey)
	}
	
	private static var cachedUpdateURLString: String? {
		UserDefaults.standard.string(forKey: cachedUpdateURLKey)
	}
	
	private static var cachedLatestVersionName: String? {
		UserDefaults.standard.string(forKey: cachedLatestVersionNameKey)
	}
	
	private static var cachedUpdateURL: URL? {
		cachedUpdateURLString.flatMap(URL.init(string:))
	}
	
	// MARK: - Fetching

	/// Every check must read FRESH values. A plain GET can be served
	/// stale — the phone's network cached the old 'null' answer from
	/// before minVersion was set, so the check kept reporting "no
	/// block" even after the server said 3 (proven 2026-11-25: signing
	/// passed with minVersion=3 live). Each request therefore bypasses
	/// every cache: URLSession cache, proxies and edges.
	///
	/// Headers alone were NOT enough: on 2026-11-26 v2.2 (build 4)
	/// relaunched many times with minVersion=5 live and still opened
	/// — the network served a stale answer despite the no-cache
	/// headers. So every request now ALSO carries a unique query
	/// parameter (?cb=<current milliseconds>): a cache keyed by URL
	/// can never serve a stale answer for a never-seen URL. The RTDB
	/// REST API ignores unknown query params (verified by curl).
	private func _noCacheRequest(for url: URL) -> URLRequest {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		var items = components?.queryItems ?? []
		items.append(URLQueryItem(name: "cb", value: String(Int(Date().timeIntervalSince1970 * 1000))))
		components?.queryItems = items
		let freshURL = components?.url ?? url
		var request = URLRequest(url: freshURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
		request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
		request.setValue("no-cache", forHTTPHeaderField: "Pragma")
		return request
	}
	
	/// Returns (value, succeeded). A JSON `null` means the value is
	/// absent (succeeded, value nil). Any transport or decode error
	/// means the fetch failed (succeeded false).
	private func _tryFetchString(from url: URL) async -> (value: String?, succeeded: Bool) {
		do {
			return (try await _fetchString(from: url), true)
		} catch {
			return (nil, false)
		}
	}
	
	private func _tryFetchBool(from url: URL) async -> (value: Bool?, succeeded: Bool) {
		do {
			return (try await _fetchBool(from: url), true)
		} catch {
			return (nil, false)
		}
	}
	
	/// Returns (value, succeeded). A JSON `null` means the value is
	/// absent (succeeded, value nil). Any transport or decode error
	/// means the fetch failed (succeeded false).
	private func _tryFetchInt(from url: URL) async -> (value: Int?, succeeded: Bool) {
		do {
			return (try await _fetchInt(from: url), true)
		} catch {
			return (nil, false)
		}
	}
	
	private func _fetchString(from url: URL) async throws -> String? {
		let (data, response) = try await _session.data(for: _noCacheRequest(for: url))
		guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
			throw ForcedUpdateError.checkFailed
		}
		if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
			return nil
		}
		return try JSONDecoder().decode(String.self, from: data)
	}
	
	private func _fetchBool(from url: URL) async throws -> Bool? {
		let (data, response) = try await _session.data(for: _noCacheRequest(for: url))
		guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
			throw ForcedUpdateError.checkFailed
		}
		if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
			return nil
		}
		return try JSONDecoder().decode(Bool.self, from: data)
	}
	
	/// Decodes a JSON number (e.g. 2) or a numeric string (e.g. "2"),
	/// because the value is set by hand and either form may be used.
	/// A JSON float such as 2.0 decodes to 2. Anything else is a
	/// failed fetch, never a guessed value.
	private func _fetchInt(from url: URL) async throws -> Int? {
		let (data, response) = try await _session.data(for: _noCacheRequest(for: url))
		guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
			throw ForcedUpdateError.checkFailed
		}
		if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
			return nil
		}
		let json = try JSONSerialization.jsonObject(with: data)
		if let number = json as? NSNumber {
			return number.intValue
		}
		if let string = json as? String {
			return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
		}
		throw ForcedUpdateError.checkFailed
	}
}
