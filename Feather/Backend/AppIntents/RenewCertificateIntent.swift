//
//  RenewCertificateIntent.swift
//  Feather
//
//  Zenith v2.2 — Siri Shortcut "جدّد الشهادة" (Renew Certificate).
//
//  Runs the same current-certificate renewal path as the Certificates
//  tab toolbar button: AutoRefreshManager.refreshDueApps(). That path
//  re-signs due apps with the CURRENT certificate — an imported
//  enterprise certificate is used directly, no Apple ID session is
//  needed (see AutoRefreshManager._certificateForResigning()).
//
//  The intent opens the app when run (openAppWhenRun): re-signing
//  needs foreground file access, the network (forced-update check),
//  and Zsign, none of which is safe from a background intent process.
//
//  Honesty: the result dialog always says what actually happened —
//  renewed apps by name, nothing due, or the real failure reason.
//  It never reports success when nothing was renewed.

import AppIntents
import Foundation

struct RenewCertificateIntent: AppIntent {
	static var title: LocalizedStringResource = "جدّد الشهادة"
	static var description = IntentDescription("جدّد شهادة Zenith ووقّع التطبيقات اللي قربت تنتهي.")
	static var openAppWhenRun: Bool { true }

	func perform() async throws -> some IntentResult {
		let due = await AutoRefreshManager.shared.dueApps()
		guard !due.isEmpty else {
			return .result(dialog: "ما عندك شي يحتاج تجديد هسه، كل التطبيقات موقّعة بشهادة سارية.")
		}

		let report = await AutoRefreshManager.shared.refreshDueApps()

		if report.refreshedAppNames.isEmpty {
			// Everything failed: say so, with the real reason.
			let detail = report.failed.first.map {
				"\($0.name): \($0.error.localizedDescription)"
			} ?? "ما قدرت أجدّد الشهادة. تأكد من النت وحاول مرة ثانية."
			return .result(dialog: "ما قدرت أجدّد الشهادة: \(detail)")
		}

		let refreshed = report.refreshedAppNames.joined(separator: "، ")
		if report.failed.isEmpty {
			return .result(dialog: "جدّدت الشهادة ووقّعت \(refreshed).")
		}

		// Partial success: name what worked and what did not.
		let failed = report.failed.map {
			"\($0.name): \($0.error.localizedDescription)"
		}.joined(separator: "، ")
		return .result(dialog: "جدّدت الشهادة ووقّعت \(refreshed)، بس ما قدرت أجدّد \(failed).")
	}
}

/// Surfaces the intent in the Shortcuts app so the user can add it
/// and invoke it with the listed Siri phrases.
struct ZenithShortcutsProvider: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: RenewCertificateIntent(),
			phrases: [
				"جدّد الشهادة في \(.applicationName)",
				"جدّد شهادة \(.applicationName)"
			],
			shortTitle: "جدّد الشهادة",
			systemImageName: "arrow.clockwise"
		)
	}
}
