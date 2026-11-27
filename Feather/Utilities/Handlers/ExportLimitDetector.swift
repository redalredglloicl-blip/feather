
//
//  ExportLimitDetector.swift
//  Zenith
//
//  Zenith v2.12, item 14 (#41): find limits on exporting /
//  sharing from an imported .app bundle and offer to remove them
//  before signing.
//
//  HONEST LIMITS — the UI states all of these plainly:
//  * Only limits stored LOCALLY can be changed: a number cap in
//    a bundled .plist / .json file (raised to 999999), or a Bool
//    gate that switches a limit on (switched off). Only keys
//    that already exist are changed — no keys are invented.
//  * A limit that is a plain number is raised, not deleted: the
//    app may still read the key, so the value is set far above
//    anything reachable instead of inventing an "unlimited" flag
//    the app may not understand.
//  * String caps (e.g. a quality cap stored as "720p") are shown
//    but NOT offered for change: rewriting a quality label to a
//    guessed value could break the app or do nothing, so no fake
//    removal is offered for them.
//  * Limits enforced server-side (export counts or quality tied
//    to the account or subscription on the developer's server)
//    cannot be removed from the device.
//

import Foundation

// MARK: - Model

/// One local export/share limit found inside the .app bundle,
/// with the change that would lift it. Nil change means the value
/// is shown for information only.
struct ExportLimitFinding: Identifiable, Equatable {
	var id: String { finding.id }

	var finding: AppConfigFinding
	/// The staged change that lifts the limit, or nil when this
	/// value cannot be changed safely from the device.
	var proposedChange: AppConfigChange?

	/// True when this value cannot be changed safely, so the row
	/// is information-only.
	var isReportOnly: Bool { proposedChange == nil }
}

/// The outcome of the export-limit scan.
struct ExportLimitReport: Equatable {
	var findings: [ExportLimitFinding]
}

// MARK: - Detector

enum ExportLimitDetector {
	/// The number a raised cap is set to: far above anything
	/// reachable, instead of an invented "unlimited" flag the app
	/// may not understand.
	static let raisedLimit: Double = 999999

	/// Substrings that mark a key as export/share-related.
	/// Matching is case-insensitive.
	static let keyPatterns = ["export", "sharelimit", "maxshare"]
	/// Substrings in a file name that mark the whole file as
	/// config worth parsing.
	static let fileNameHints = [
		"config", "settings", "remote", "feature", "flags",
		"defaults", "preferences", "constants", "app",
		"export", "share", "media", "editor", "subscription",
	]

	/// Scans `appDirectory` (a `.app` bundle) for local export /
	/// share limits. Synchronous — call from a background queue.
	static func detect(appDirectory: URL) -> ExportLimitReport {
		let found = AppConfigScanner.scan(
			appDirectory: appDirectory,
			keyPatterns: keyPatterns,
			fileNameHints: fileNameHints
		)
		var results: [ExportLimitFinding] = []
		for finding in found {
			results.append(ExportLimitFinding(
				finding: finding,
				proposedChange: _proposedChange(for: finding)
			))
		}
		return ExportLimitReport(findings: results)
	}

	/// Decides the staged change for one found value, or nil when
	/// it cannot be changed safely from the device.
	private static func _proposedChange(for finding: AppConfigFinding) -> AppConfigChange? {
		let key = finding.key.lowercased()
		switch finding.value {
		case .number:
			// A number cap is only a limit when its name says so
			// ("maxExportCount", "exportLimit", ...). A bare
			// counter ("exportedCount") is not a limit, and
			// raising it would do nothing.
			guard key.contains("limit") || key.contains("max") || key.contains("cap") else {
				return nil
			}
			return AppConfigChange(
				relativePath: finding.relativePath,
				key: finding.key,
				value: .number(raisedLimit)
			)
		case .bool(let isOn):
			if key.contains("limit") || key.contains("restrict") {
				// A gate that switches a limit on gets switched
				// off. A gate that is already off is shown as
				// already-off.
				return isOn ? AppConfigChange(
					relativePath: finding.relativePath,
					key: finding.key,
					value: .bool(false)
				) : nil
			}
			if key.contains("enabled") || key.contains("allowed") {
				// A gate that switches exporting on gets switched
				// on. A gate that is already on is shown as
				// already-on.
				return isOn ? nil : AppConfigChange(
					relativePath: finding.relativePath,
					key: finding.key,
					value: .bool(true)
				)
			}
			return nil
		case .string:
			// A quality / length cap stored as text (e.g. "720p")
			// is shown but never rewritten to a guessed value.
			return nil
		}
	}
}
