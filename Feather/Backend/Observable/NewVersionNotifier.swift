//
//  NewVersionNotifier.swift
//  Zenith
//
//  Zenith v2.2 — tells the user when a newer Zenith build is released.
//
//  Source of truth: /feather-app/latestVersion in the same Firebase
//  RTDB project as the forced-update check (spychat-4f8d5), read with
//  the same no-cache GET pattern as ForcedUpdateManager. It is a build
//  NUMBER (same integer scale as ZenithBuildNumber), not a version
//  string. The coordinator writes it when a new build is released;
//  while the key is absent nothing is notified.
//
//  Why latestVersion and not minVersion: minVersion is the minimum
//  REQUIRED build — when it passes the installed build the forced
//  update screen already blocks the app, so a notification would be
//  redundant. latestVersion is the newest RELEASED build, so this
//  notifier covers the non-forced case too.
//
//  Rules:
//  * Offline or key absent -> silent, no notification, no banner.
//  * Never notify about the same build twice: the last notified
//    build is persisted (Zenith.lastNotifiedBuild).
//  * Notification permission granted -> one local notification.
//  * Permission denied -> in-app banner instead, never a crash.
//  * Permission not yet decided -> ask once, then notify or banner.
//  * If the forced-update screen is already blocking the app, skip:
//    the user is already looking at the update screen.

import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class NewVersionNotifier: ObservableObject {
	static let shared = NewVersionNotifier()

	private static let baseURL = "https://spychat-4f8d5-default-rtdb.firebaseio.com/feather-app"
	private static var latestVersionURL: URL { URL(string: "\(baseURL)/latestVersion.json")! }
	private static var latestVersionNameURL: URL { URL(string: "\(baseURL)/latestVersionName.json")! }

	private static let lastNotifiedBuildKey = "Zenith.lastNotifiedBuild"

	/// True when the banner should be shown (permission denied case).
	@Published private(set) var showBanner = false
	/// The newer build the banner is about, when known.
	@Published private(set) var latestBuild: Int?
	/// The new version's display name (e.g. "2.3") from
	/// /feather-app/latestVersionName, when the server knows it.
	@Published private(set) var latestVersionName: String?
	/// Where the banner's update button goes, when known.
	@Published private(set) var updateURL: URL?

	private var _isChecking = false

	private let _session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 15
		config.timeoutIntervalForResource = 20
		return URLSession(configuration: config)
	}()

	private init() {}

	/// Checks for a newer build. Safe to call on every launch and on
	/// every foreground return; concurrent callers share one check.
	func checkForNewVersion() async {
		guard !_isChecking else { return }
		_isChecking = true
		defer { _isChecking = false }

		guard let latest = await _fetchLatestVersion() else {
			// Offline, or the key is not set yet: stay silent.
			return
		}

		// The display name is best-effort: the banner shows the
		// plain headline when the field is absent.
		latestVersionName = await _fetchLatestVersionName()

		let installed = ForcedUpdateManager.installedBuildNumber
		guard latest > installed else {
			// Already on the newest build (or newer): hide the banner.
			showBanner = false
			latestBuild = nil
			latestVersionName = nil
			updateURL = nil
			return
		}

		// The forced-update screen already tells the user when the
		// build is required; do not pile a notification on top of it.
		guard !ForcedUpdateManager.shared.isUpdateRequired else { return }

		guard latest != _lastNotifiedBuild else {
			// Already notified about this build once.
			return
		}

		latestBuild = latest
		updateURL = ForcedUpdateManager.shared.updateURL

		let status = await _notificationStatus()
		switch status {
		case .authorized, .provisional, .ephemeral:
			_notify(build: latest)
		case .denied:
			showBanner = true
		case .notDetermined:
			if await _requestAuthorization() {
				_notify(build: latest)
			} else {
				showBanner = true
			}
		@unknown default:
			showBanner = true
		}
	}

	/// Hides the banner and records this build as notified, so it is
	/// not shown again on the next launch or foreground return.
	func dismissBanner() {
		if let latest = latestBuild {
			UserDefaults.standard.set(latest, forKey: Self.lastNotifiedBuildKey)
		}
		showBanner = false
	}

	// MARK: - Notify

	private func _notify(build: Int) {
		let content = UNMutableNotificationContent()
		content.title = .localized("New Zenith version available")
		content.body = .localized("New Zenith build %lld is available. Update now.", arguments: build)
		content.sound = .default

		let request = UNNotificationRequest(
			identifier: "zenith.new-version.\(build)",
			content: content,
			trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
		)
		UNUserNotificationCenter.current().add(request) { _ in }
		// Recorded only when the notification was actually scheduled,
		// so a failed schedule retries on the next launch.
		UserDefaults.standard.set(build, forKey: Self.lastNotifiedBuildKey)
	}

	// MARK: - Permission

	private func _notificationStatus() async -> UNAuthorizationStatus {
		await withCheckedContinuation { continuation in
			UNUserNotificationCenter.current().getNotificationSettings { settings in
				continuation.resume(returning: settings.authorizationStatus)
			}
		}
	}

	private func _requestAuthorization() async -> Bool {
		await withCheckedContinuation { continuation in
			UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
				continuation.resume(returning: granted)
			}
		}
	}

	// MARK: - Cache

	private var _lastNotifiedBuild: Int? {
		let value = UserDefaults.standard.object(forKey: Self.lastNotifiedBuildKey)
		if let number = value as? NSNumber {
			return number.intValue
		}
		if let string = value as? String {
			return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
		}
		return nil
	}

	// MARK: - Fetching (same no-cache pattern as ForcedUpdateManager)

	private func _fetchLatestVersion() async -> Int? {
		do {
			return try await _fetchInt(from: Self.latestVersionURL)
		} catch {
			return nil
		}
	}

	private func _fetchLatestVersionName() async -> String? {
		do {
			return try await _fetchString(from: Self.latestVersionNameURL)
		} catch {
			return nil
		}
	}

	/// Decodes a JSON string (e.g. "2.3"). A JSON null means the
	/// value is absent. Anything else is nil.
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

	/// Every check must read FRESH values: plain GETs can be served
	/// stale from a cache. Each request bypasses every cache — and
	/// carries a unique ?cb=<milliseconds> query parameter, because
	/// no-cache headers alone were proven insufficient on device
	/// (2026-11-26: the forced-update check kept reading a stale
	/// answer despite them). A cache keyed by URL can never serve a
	/// stale answer for a never-seen URL; the RTDB REST API ignores
	/// unknown query params.
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

	/// Decodes a JSON number (e.g. 4) or a numeric string (e.g. "4").
	/// A JSON null means the value is absent. Anything else is nil.
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

// MARK: - In-app banner (shown when notification permission is denied)

struct NewVersionBannerView: View {
	@ObservedObject var notifier: NewVersionNotifier

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "arrow.down.circle.fill")
				.foregroundStyle(Color(hex: "#FFC778"))
				.font(.title3)

			VStack(alignment: .leading, spacing: 2) {
				Text(.localized("New Zenith version available"))
					.font(.headline)
					.lineLimit(2)

				if let name = notifier.latestVersionName {
					Text(verbatim: "Zenith \(name)")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			}

			Spacer()

			if let url = notifier.updateURL {
				Button(.localized("Update")) {
					UIApplication.shared.open(url)
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
			}

			Button {
				notifier.dismissBanner()
			} label: {
				Image(systemName: "xmark")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}
		.padding()
		.zenithGlassCard(cornerRadius: 14, fallback: Color(uiColor: .secondarySystemFill))
		.padding(.horizontal)
		.padding(.top, 8)
	}
}
