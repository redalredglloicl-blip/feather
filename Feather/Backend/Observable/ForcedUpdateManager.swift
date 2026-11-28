
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
//  * A check that fails does NOT pass the app on its own. The decisive
//    fetches (minVersion, killed) are retried (2 attempts, 1 s apart,
//    5 s timeouts — v2.40, was 3 attempts, 2 s apart, 15 s timeouts)
//    while the device reports connectivity. The launch screen used to
//    wait for a FRESH decision — both decisive fields fetched live —
//    before the app opened (see LoadingView step 4). Build 12 proved
//    why: its check failed on a weak connection, fell back to the
//    cached minVersion 11, and opened while the server said 13.
//    v2.12 bounded that wait (~30 s): if no fresh decision arrived,
//    the launch opened on the cached decision instead of hanging
//    forever (build 13 hung at 75% across restarts for exactly this
//    reason). v2.40 removed the wait itself for the cached case: the
//    launch now opens at once on a cached "fine" and refreshes the
//    check in the background, because the fresh fetch effectively
//    never completes on this phone and every launch parked at 75%
//    for the whole deadline. A later fresh check that blocks still
//    flips the UI to the update screen the moment it answers.
//    v2.13: signing/installing follow the SAME decision the
//    launch gate uses (see ensureSignAllowed) — a fresh pass, or a
//    cached decision that says this build is fine — because the
//    fresh check never completes on this phone at all, so the old
//    fresh-only signing gate blocked signing forever on a build the
//    launch gate had already opened on.
//  * The cache is still applied on a failed check, so a cached block
//    STAYS blocked and shows instantly, and a single dropped request
//    can never lift a block. A cached "fine" still never sets
//    hasPassedCheck — only a fresh check passes — and only a field
//    that succeeded fresh may clear or overwrite its cache. But a
//    cached "fine" DOES open the app at launch (v2.40: at once, no
//    deadline wait; before that the v2.12 deadline fallback) and DOES
//    allow signing/installing (v2.13, ensureSignAllowed): the launch
//    gate and the signing gate use the same cached decision, so a
//    build the launch opened on is a build that can sign.
//  * Every check (launch and foreground) applies the cached decision
//    FIRST, before any network, so a cached block shows instantly
//    and a backgrounded old app re-blocks the moment it foregrounds.
//  * Signing and installing run when the launch decision allows them:
//    a fresh check passed (in-memory flag, set only by a real check
//    that found no block), OR a cached decision exists and says this
//    build is fine (see ensureSignAllowed). A known block — fresh or
//    cached — still refuses, and with no cached decision at all the
//    gate still waits for a fresh check instead of guessing. When no
//    fresh check has run yet this session the gate re-runs the check
//    on demand, so a transient failure only delays the action until
//    the network is back; when the launch check already tried fresh
//    this session, the cached decision answers at once instead of
//    burning another full retry round first.
//  * Genuinely offline (no Wi-Fi and no mobile data) is owned by the
//    no-internet gate (OfflineBlockView), not this manager: the retry
//    loop stops as soon as the device reports offline, and the launch
//    screen stops waiting, so the app is never bricked by a retry loop.
//
//  Honest limits: this is a server-side gate, not a vault. A
//  determined attacker with a decrypted IPA can patch the check out
//  of the binary and re-sign it. What the gate DOES do: it cannot be
//  bypassed by blocking the network (a failed check refuses signing
//  instead of allowing it), and it cannot be bypassed by editing the
//  app's stored data (the pass flag lives only in memory; the minimum
//  version comes from the server, not the device).
//
//  v2.12: the launch waits at most ~30 s for a fresh decision and
//  then opens on the last known (cached) decision instead of hanging
//  forever — build 13 proved a failed check can persist across
//  restarts on this phone, so waiting longer only bricks the app
//  (see LoadingView step 4). The residual hole is honest and
//  unavoidable client-side: if the server raised minVersion AND the
//  fetch cannot complete at all, the app opens on stale cache —
//  it cannot know what it cannot fetch. A later fresh check that
//  blocks flips the UI to the update screen the moment it answers.
//
//  v2.40: the launch no longer waits at all when a cached decision
//  exists — it opens at once on a cached "fine" (background refresh
//  still runs) and the no-cache wait is now ~12 s with 5 s fetch
//  timeouts. The 30 s deadline and the 15 s timeouts were the
//  75% stall: the fresh fetch effectively never completes on this
//  phone, so every launch sat at step 4 until the deadline.
//
//  v2.13: the signing/installing gate follows the launch decision
//  (ensureSignAllowed). The fresh check NEVER completes on this
//  phone — proven across v2.2–v2.12 despite strong internet — so
//  the old fresh-only signing gate refused every sign/install with
//  "ما قدرت أتأكد من إصدار التطبيق" on a build the launch gate had
//  already opened on. Signing now allows what the launch allowed:
//  a fresh pass, or a cached "fine". The residual hole is the same
//  one the launch already accepts (above): a stale cached "fine"
//  cannot know the server raised minVersion. A known block still
//  refuses signing, and a later fresh check that blocks flips the
//  UI to the update screen the moment it answers.
//
//  Already-installed old builds run their own frozen gate code and
//  cannot be fixed by changing this file: v1 has no gate at all, and
//  v2.2 (build 4, old bundle ID) fetches without the ?cb cache-buster
//  and was proven to keep serving a stale "not blocked" answer. Only
//  the server values can reach those builds, through their own
//  stale-prone fetch path — deleting the old app from the phone is
//  the reliable stop for them.

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
	
	/// Set ONLY by a real check that completed fresh and found no block.
	/// A check that fell back to the cache never sets it, even when the
	/// cached values say the app is fine. Lives in memory only — a
	/// relaunch must check again. Signing/installing no longer read
	/// this flag alone — see ensureSignAllowed(), which also honours
	/// a cached "fine" — so the flag stays the fresh-only pass.
	private(set) var hasPassedCheck = false

	/// True once a check has applied a FRESH decision — both decisive
	/// fields (minVersion and killed) fetched live. The launch screen
	/// waits for this before the app opens. In-memory only: every
	/// launch starts false and must earn it again.
	@Published private(set) var hasFreshDecision = false

	/// Counts every fetch attempt (each round of the retry loop). The
	/// launch screen shows it while retrying, so a retrying launch
	/// never looks frozen.
	@Published private(set) var checkAttempts = 0

	/// True once the launch may proceed: a fresh decision was applied,
	/// a cached block was applied, or the deadline fallback opened the
	/// app on the cached decision. The launch screen waits on this,
	/// not on hasFreshDecision alone (v2.12: build 13 proved a failed
	/// check can persist across restarts, so waiting only for a fresh
	/// decision bricks the app).
	@Published private(set) var hasLaunchDecision = false

	/// True when the launch decision came from the cache (deadline
	/// fallback). hasPassedCheck stays false then — but signing and
	/// installing follow the cached decision itself (v2.13,
	/// ensureSignAllowed), so a cached "fine" still allows them.
	@Published private(set) var launchUsedCache = false
	
	private var _checkTask: Task<Void, Never>?
	
	private let _session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		// v2.40: short timeouts — a slow network must never park the
		// launch screen at 75% for long. Was 15 s / 20 s, which let
		// one retry round alone run ~45 s.
		config.timeoutIntervalForRequest = 5
		config.timeoutIntervalForResource = 8
		return URLSession(configuration: config)
	}()
	
	private init() {
		// Cache first: if a previous run already learned this build
		// is old, stay blocked from the very first frame — the network
		// check below can only lift the block, never delay it.
		_applyCachedDecision()
	}

	/// Applies the cached decision synchronously, with no network.
	/// Called from init (first frame) and at the start of every
	/// check (launch + foreground): if a previous run already learned
	/// this build is old, the app blocks instantly instead of staying
	/// usable while the fresh fetch runs. It NEVER un-blocks: a live
	/// block can only be lifted by a fresh fetch that says so (in
	/// _apply), never by the cache — so a flaky fetch can never undo
	/// a cached block.
	private func _applyCachedDecision() {
		// The cached version name (if any) shows from the first frame.
		latestVersionName = Self.cachedLatestVersionName
		if let cached = Self.cachedMinVersion,
		   Self.installedBuildNumber < cached {
			isUpdateRequired = true
			hasPassedCheck = false
			updateURL = Self.cachedUpdateURL
		} else if Self.cachedKilled {
			isUpdateRequired = true
			hasPassedCheck = false
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
		// Cache first, before any network: a backgrounded old app
		// re-blocks the moment it foregrounds, with no wait for the
		// fresh fetch — and no wait for its failure either. Runs
		// before the in-flight join below, so it applies even while
		// another check is still running.
		_applyCachedDecision()
		if let inFlight = _checkTask {
			await inFlight.value
			return
		}
		let task = Task { await _performCheck() }
		_checkTask = task
		await task.value
		_checkTask = nil
	}
	
	/// Returns true only when a FRESH check has passed. Runs the check
	/// on demand when it has not passed yet. The flag is set only by a
	/// real check that completed fresh and found no block — a cached
	/// decision never sets it. Kept as the strict fresh-only primitive;
	/// the signing/installing gates use ensureSignAllowed() instead.
	func ensureCheckPassed() async -> Bool {
		if hasPassedCheck {
			return true
		}
		await checkForUpdate()
		return hasPassedCheck
	}

	/// True when a cached decision exists and says this build is fine:
	/// the cached kill flag is off and the installed build is at or
	/// above the cached minimum version. Requires at least one cached
	/// value — with no cache at all there is no decision to fall back
	/// on, so this is false and signing still waits for a fresh check.
	/// The exact negation of the cached block in _applyCachedDecision,
	/// so a cached block can never read as "fine" here.
	var cachedDecisionAllowsSigning: Bool {
		guard hasAnyCachedValue else { return false }
		if Self.cachedKilled { return false }
		if let minVersion = Self.cachedMinVersion,
		   Self.installedBuildNumber < minVersion {
			return false
		}
		return true
	}

	/// Signing/installing gate (v2.13). Allows exactly what the launch
	/// gate allows: (a) a fresh check passed, or (b) a cached decision
	/// exists and says this build is fine. A known block — fresh or
	/// cached — still refuses, and with no cached decision the gate
	/// still waits for a fresh check instead of guessing. This does
	/// NOT set hasPassedCheck: that flag stays fresh-only, so a
	/// cached "fine" allows signing without ever claiming a live
	/// check passed. When the launch check already tried fresh this
	/// session (checkAttempts > 0), the cached decision answers at
	/// once instead of burning another full retry round first — the
	/// launch already waited for fresh and opened on this same
	/// decision. A fresh check that lands later and blocks still
	/// flips the UI to the update screen the moment it answers.
	func ensureSignAllowed() async -> Bool {
		if hasPassedCheck {
			return true
		}
		if isUpdateRequired {
			return false
		}
		if checkAttempts > 0, cachedDecisionAllowsSigning {
			return true
		}
		if await ensureCheckPassed() {
			return true
		}
		if isUpdateRequired {
			return false
		}
		return cachedDecisionAllowsSigning
	}

	/// Launch-screen deadline fallback (v2.12). Call when the fresh
	/// check could not complete within the launch deadline: open on
	/// the last known (cached) decision instead of hanging forever.
	/// Build 13 hung at 75% across restarts because its check never
	/// completed fresh on this phone — waiting longer only bricks
	/// the app. hasPassedCheck stays false, but signing and installing
	/// follow the cached decision itself (v2.13, ensureSignAllowed);
	/// a later fresh check that blocks flips the UI to the update
	/// screen the moment it answers. Never call when a fresh decision
	/// already exists.
	func applyCachedFallbackForLaunch() {
		_applyCachedDecision()
		launchUsedCache = true
		hasLaunchDecision = true
	}

	/// True when the cache holds any value a launch decision can be
	/// made from (a minimum version or a kill flag ever fetched live).
	/// Presence-based: a stored `false` kill flag still counts,
	/// because it proves a check completed once.
	var hasAnyCachedValue: Bool {
		Self.cachedMinVersion != nil || UserDefaults.standard.object(forKey: Self.cachedKilledKey) != nil
	}
	
	// MARK: - Private
	
	private func _performCheck() async {
		guard !isChecking else { return }
		isChecking = true
		defer { isChecking = false }
		
		// Decisive fields (minVersion, killed) are retried: a single
		// dropped request on a weak connection must never decide the
		// launch. First success wins per field; later rounds re-fetch
		// every field (idempotent GETs) but only a field that has not
		// succeeded yet takes the new result. Non-decisive fields
		// (update URL, version name) ride along opportunistically —
		// their failure never blocks the decision.
		var minVersionResult: (value: Int?, succeeded: Bool) = (nil, false)
		var killedResult: (value: Bool?, succeeded: Bool) = (nil, false)
		var updateURLResult: (value: String?, succeeded: Bool) = (nil, false)
		var nameResult: (value: String?, succeeded: Bool) = (nil, false)

		// v2.40: 2 attempts, 1 s apart, 5 s per-request timeout.
		// Worst case on a dead-but-"online" connection is ~2 x 5 s
		// timeouts + gaps before the caller retries again (was 3
		// attempts, 2 s apart, 15 s timeouts: ~45 s a round, which
		// parked the launch at 75% for the whole ~30 s deadline
		// even when a cached "fine" existed — the launch now opens
		// on the cache at once instead, see LoadingView step 4).
		for attempt in 1...2 {
			checkAttempts += 1
			async let minVersionFetch = _tryFetchInt(from: Self.minVersionURL)
			async let killedFetch = _tryFetchBool(from: Self.killedURL)
			async let updateURLFetch = _tryFetchString(from: Self.updateURLValue)
			async let nameFetch = _tryFetchString(from: Self.latestVersionNameURL)
			let mv = await minVersionFetch
			let kl = await killedFetch
			let uu = await updateURLFetch
			let nm = await nameFetch
			if !minVersionResult.succeeded { minVersionResult = mv }
			if !killedResult.succeeded { killedResult = kl }
			if !updateURLResult.succeeded { updateURLResult = uu }
			if !nameResult.succeeded { nameResult = nm }

			// Both decisive fields fresh: nothing left to retry for.
			if minVersionResult.succeeded && killedResult.succeeded { break }
			// No connectivity at all: stop burning attempts — the
			// no-internet gate (OfflineBlockView) owns this case, and
			// the check re-runs when connectivity returns.
			if NetworkMonitor.shared.isOffline { break }
			if Task.isCancelled { break }
			if attempt < 2 {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}
		
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
			// A failed fetch must NEVER read as "no enforcement":
			// fall back to the cached value for that one field, so a
			// single dropped request cannot lift a block (or pass the
			// check) while its siblings succeed. Only a field that
			// succeeded fresh may clear or overwrite its cache (above).
			// When a decisive field (minVersion / killed) came from
			// the cache, the decision counts as cached, not fresh:
			// it can hold a block, but it can never pass the app.
			let usedCacheForDecision = !minVersionResult.succeeded || !killedResult.succeeded
			_apply(
				minVersion: minVersionResult.succeeded ? minVersionResult.value : Self.cachedMinVersion,
				killed: killedResult.succeeded ? (killedResult.value ?? false) : Self.cachedKilled,
				updateURLString: updateURLResult.succeeded ? updateURLResult.value : Self.cachedUpdateURLString,
				latestVersionName: nameResult.succeeded ? nameResult.value : Self.cachedLatestVersionName,
				fromCache: usedCacheForDecision
			)
		} else {
			// All fetches failed even after retries: fall back to the
			// cache for the BLOCK decision only. A cached "fine" does
			// not pass the check (see _apply) and does not set
			// hasFreshDecision, so the launch screen keeps waiting
			// and re-runs the check instead of opening on a guess.
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
			// A block IS a decision — the block screen shows
			// immediately; never wait out a deadline for it.
			hasLaunchDecision = true
		} else {
			isUpdateRequired = false
			// Only a FRESH check passes. A failed check that fell back
			// to the cache never passes: the cached minVersion is from
			// an older server state — build 12 passed on cached 11
			// while the server already said 13 — so a cached "fine"
			// is not proof this build is still allowed. Signing and
			// installing read the cached decision itself instead
			// (v2.13, ensureSignAllowed) — they do not read this flag.
			hasPassedCheck = !fromCache
		}
		// A fresh decision means BOTH decisive fields (minVersion and
		// killed) were fetched live this check. The launch screen waits
		// for this flag. In-memory only: every launch must earn it again.
		if !fromCache {
			hasFreshDecision = true
			hasLaunchDecision = true
		}
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
		var request = URLRequest(url: freshURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
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
