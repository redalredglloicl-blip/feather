
//
//  GuestLoginDetector.swift
//  Zenith
//
//  Zenith v2.12, item 20 (#61): use an app without an account.
//
//  The screen scans the imported .app for local login /
//  onboarding gates — Bool keys in the app's own Info.plist,
//  other bundled .plist/.json files, or toggles in the app's
//  Settings.bundle — reusing AppConfigScanner, and offers to flip
//  each gate that has a clear guest meaning (for example a
//  `requiresLogin` flag set to true becomes false, an
//  `onboardingCompleted` flag set to false becomes true). The
//  chosen flips are staged in Options.guestLoginChanges as
//  AppConfigChange values and set by the already-wired
//  AppConfigApplier at signing time, before re-signing.
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * Only LOCAL gates can be flipped: a Bool key that already
//    exists in a bundled config file. No keys are invented,
//    because an invented key does nothing, and a key whose
//    meaning cannot be read from its name is never guessed at —
//    it is counted, not offered.
//  * Most account systems verify server-side and CANNOT be
//    bypassed from the device. If no local gate is found, the UI
//    says so plainly and offers nothing fake.
//  * Flipping a local gate only asks the app to skip its own
//    login screen; some apps ignore the flag or check the
//    account on their server anyway, so a flipped gate is not a
//    promise the app will open as a guest.
//

import Foundation

// MARK: - Model

/// One local gate that may force a login / onboarding screen.
struct GuestLoginGate: Identifiable, Equatable {
	var id: String { relativePath + "#" + key }

	/// Path inside the .app, e.g. `Info.plist` or `Config.plist`.
	var relativePath: String
	/// The plist / JSON key (or Settings.bundle preference Key).
	var key: String
	/// The gate's current value in the bundle.
	var currentValue: AppConfigValue
	/// The value that lets the user in as a guest.
	var proposedValue: AppConfigValue
}

/// The outcome of the login-gate scan.
struct GuestLoginReport: Equatable {
	var gates: [GuestLoginGate]
	/// Gates already in their guest state (nothing to flip).
	var alreadyGuestCount: Int
	/// Local login-looking keys found but not offered, because
	/// their meaning cannot be read from the name or their value
	/// is not a Bool.
	var unflippableCount: Int
}

// MARK: - Detector

enum GuestLoginDetector {
	/// Substrings that mark a key as login / onboarding related.
	/// Matching is case-insensitive.
	static let keyPatterns = [
		"login", "signin", "sign-in", "auth", "onboarding",
		"guest", "account", "register",
	]
	/// Substrings in a file name that mark the whole file as
	/// login / onboarding related.
	static let fileNameHints = [
		"config", "settings", "onboarding", "auth", "login",
		"account", "user", "app", "preferences", "flags",
	]

	/// Scans `appDirectory` (a `.app` bundle) for local login /
	/// onboarding gates. Synchronous — call from a background
	/// queue.
	static func detect(appDirectory: URL) -> GuestLoginReport {
		let findings = AppConfigScanner.scan(
			appDirectory: appDirectory,
			keyPatterns: keyPatterns,
			fileNameHints: fileNameHints
		)

		var gates: [GuestLoginGate] = []
		var alreadyGuestCount = 0
		var unflippableCount = 0

		for finding in findings {
			guard case .bool(let current) = finding.value else {
				// A number or String login key (for example an
				// onboarding step count) cannot be flipped safely
				// without knowing what its values mean.
				unflippableCount += 1
				continue
			}
			guard let proposed = _proposedValue(for: finding.key, current: current) else {
				// The key looks login-related but its guest
				// meaning cannot be read from the name — never
				// guess, just count it.
				unflippableCount += 1
				continue
			}
			if proposed == finding.value {
				alreadyGuestCount += 1
				continue
			}
			gates.append(GuestLoginGate(
				relativePath: finding.relativePath,
				key: finding.key,
				currentValue: finding.value,
				proposedValue: proposed
			))
		}

		gates.sort {
			if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
			return $0.key < $1.key
		}
		return GuestLoginReport(
			gates: gates,
			alreadyGuestCount: alreadyGuestCount,
			unflippableCount: unflippableCount
		)
	}

	/// The guest value for a gate key, or nil when the key's
	/// guest meaning cannot be read from its name. Only explicit
	/// patterns are mapped — anything else is left alone.
	private static func _proposedValue(for key: String, current: Bool) -> AppConfigValue? {
		let lower = key.lowercased()
		// Flags that force a login when true: turn them off.
		let forceLogin = [
			"requireslogin", "loginrequired", "mustlogin",
			"showlogin", "show_login", "forcelogin", "force_login",
			"authrequired", "requiresauth", "requirelogin",
			"needlogin", "needslogin", "loginmandatory",
		]
		if forceLogin.contains(where: { lower.contains($0) }) {
			return .bool(false)
		}
		// Flags that record a finished login / onboarding when
		// true: turn them on.
		let completed = [
			"isloggedin", "loggedin", "isauthenticated",
			"authenticated", "hasaccount", "isregistered",
			"onboardingcompleted", "hascompletedonboarding",
			"onboardingcomplete", "hasseenonboarding",
			"tutorialcompleted", "setupcompleted",
			"guestmode", "guest_mode", "skiplogin", "skip_login",
			"skipauth", "skip_auth", "isguest", "guestuser",
		]
		if completed.contains(where: { lower.contains($0) }) {
			return .bool(true)
		}
		return nil
	}
}
