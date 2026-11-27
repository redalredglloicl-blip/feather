
//
//  AppForcedUpdateDetector.swift
//  Zenith
//
//  Zenith v2.12, item 16 (#43): find the target app's own
//  forced-update prompts and offer to stop them before signing.
//
//  (This is about the APP being signed, not about Zenith itself —
//  Zenith's own forced update lives in ForcedUpdateManager and is
//  untouched here.)
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * Only LOCAL update prompts can be stopped: a Bool flag that
//    forces an update (set to false), or a locally stored minimum
//    version / build number (lowered so the current version
//    satisfies it). Only values that already exist are changed —
//    no keys are invented.
//  * An update-check endpoint (a URL the app asks for the latest
//    version) is shown but NEVER patched: pointing it at a wrong
//    address could break the app, and a server that answers
//    "update required" enforces the update anyway.
//  * Server-side enforcement cannot be stopped from the device:
//    when the app's server refuses to serve an old version, or
//    the App Store flow itself demands the update, no local patch
//    helps, and the UI says so.
//

import Foundation

// MARK: - Model

/// One local forced-update value found inside the .app bundle,
/// with the change that would stop it. Nil change means the value
/// is shown for information only (already off, or an endpoint
/// that is never patched).
struct AppForcedUpdateFinding: Identifiable, Equatable {
	var id: String { finding.id }

	var finding: AppConfigFinding
	/// The staged change that stops the forced update, or nil
	/// when this value cannot / need not be changed.
	var proposedChange: AppConfigChange?

	/// True when this value is an update-check endpoint URL: shown
	/// only, never patched.
	var isEndpoint: Bool {
		if case .string(let text) = finding.value {
			return text.lowercased().hasPrefix("http")
		}
		return false
	}

	/// True when the forced update is already off for this value,
	/// so there is nothing to change.
	var alreadyOff: Bool { proposedChange == nil && !isEndpoint }
}

/// The outcome of the forced-update scan.
struct AppForcedUpdateReport: Equatable {
	var findings: [AppForcedUpdateFinding]
}

// MARK: - Detector

enum AppForcedUpdateDetector {
	/// The version a lowered minimum version is set to: below any
	/// real release, so the installed version satisfies the check.
	static let loweredMinimumVersion = "1.0.0"
	/// The build a lowered minimum build number is set to.
	static let loweredMinimumBuild: Double = 1

	/// Substrings that mark a key as update-check-related.
	/// Matching is case-insensitive.
	static let keyPatterns = [
		"forceupdate", "forceupgrade", "minversion",
		"minimumversion", "requiredversion", "latestversion",
		"updaterequired", "mandatoryupdate", "updatecheck",
		"versioncheck", "appupdate", "minimumappversion",
		"requiredappversion", "minbuild", "minimumbuild",
		"requiredbuild",
	]
	/// Substrings in a file name that mark the whole file as
	/// config worth parsing.
	static let fileNameHints = [
		"config", "settings", "remote", "feature", "flags",
		"defaults", "preferences", "constants", "app",
		"update", "version", "appupdate",
	]

	/// Scans `appDirectory` (a `.app` bundle) for local forced
	/// update prompts. Synchronous — call from a background queue.
	static func detect(appDirectory: URL) -> AppForcedUpdateReport {
		let found = AppConfigScanner.scan(
			appDirectory: appDirectory,
			keyPatterns: keyPatterns,
			fileNameHints: fileNameHints
		)
		var results: [AppForcedUpdateFinding] = []
		for finding in found {
			results.append(AppForcedUpdateFinding(
				finding: finding,
				proposedChange: _proposedChange(for: finding)
			))
		}
		return AppForcedUpdateReport(findings: results)
	}

	/// Decides the staged change for one found value, or nil when
	/// it cannot / need not be changed safely from the device.
	private static func _proposedChange(for finding: AppConfigFinding) -> AppConfigChange? {
		let key = finding.key.lowercased()
		switch finding.value {
		case .bool(let isOn):
			// A flag that forces an update gets switched off. A
			// flag that is already off is shown as already-off.
			return isOn ? AppConfigChange(
				relativePath: finding.relativePath,
				key: finding.key,
				value: .bool(false)
			) : nil
		case .number:
			// A minimum build number gets lowered to 1, so the
			// installed build satisfies it. Only when the key
			// actually names a minimum / required build.
			guard key.contains("min") || key.contains("required") else { return nil }
			return AppConfigChange(
				relativePath: finding.relativePath,
				key: finding.key,
				value: .number(loweredMinimumBuild)
			)
		case .string(let text):
			// An update-check endpoint is shown only, never
			// patched.
			if text.lowercased().hasPrefix("http") { return nil }
			// A minimum / latest version string ("3.2.1") gets
			// lowered to 1.0.0, so the installed version satisfies
			// the check. Any other string is left alone.
			guard _isVersionString(text) else { return nil }
			guard key.contains("min") || key.contains("required")
				|| key.contains("latest") else { return nil }
			return AppConfigChange(
				relativePath: finding.relativePath,
				key: finding.key,
				value: .string(loweredMinimumVersion)
			)
		}
	}

	/// True for plain version strings like "3", "3.2", "3.2.1".
	private static func _isVersionString(_ text: String) -> Bool {
		let parts = text.split(separator: ".")
		guard !parts.isEmpty, parts.count <= 4 else { return false }
		return parts.allSatisfy { part in
			!part.isEmpty && part.allSatisfy(\.isNumber)
		}
	}
}
