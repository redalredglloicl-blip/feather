//
//  NotificationManager.swift
//  Feather
//
//  Local-only alternative to background auto-refresh: iOS does not reliably
//  wake the app to re-sign itself, so we remind the user to renew the
//  certificate while the app still works. No paid service involved.
//

import Foundation
import UserNotifications

/// Schedules local notifications reminding the user before a certificate expires.
final class NotificationManager {
	static let shared = NotificationManager()

	private init() {}

	/// Asks for notification permission once. Safe to call repeatedly;
	/// the system only prompts the user the first time.
	func requestAuthorization() {
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
	}

	/// Schedules reminders for a certificate: 3 days and 1 day before expiry.
	/// Existing reminders for the same certificate are replaced.
	func scheduleExpiryReminders(for certificate: CertificatePair) {
		guard let expiration = certificate.expiration, let uuid = certificate.uuid else { return }

		let center = UNUserNotificationCenter.current()
		let ids = [_reminderID(for: uuid, daysBefore: 3), _reminderID(for: uuid, daysBefore: 1)]
		center.removePendingNotificationRequests(withIdentifiers: ids)

		let name = certificate.nickname ?? ""
		for daysBefore in [3, 1] {
			guard let fireDate = Calendar.current.date(byAdding: .day, value: -daysBefore, to: expiration) else { continue }
			let interval = fireDate.timeIntervalSinceNow
			guard interval > 0 else { continue }

			let content = UNMutableNotificationContent()
			content.title = name.isEmpty ? .localized("Certificate expires soon") : name
			content.body = .localized("Renew now to keep signing")
			content.sound = .default

			let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
			let request = UNNotificationRequest(identifier: _reminderID(for: uuid, daysBefore: daysBefore), content: content, trigger: trigger)
			center.add(request)
		}
	}

	/// Removes all pending reminders for a certificate (call on delete).
	func cancelReminders(for certificate: CertificatePair) {
		guard let uuid = certificate.uuid else { return }
		UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
			_reminderID(for: uuid, daysBefore: 3),
			_reminderID(for: uuid, daysBefore: 1)
		])
	}

	/// Immediate local notification after a background refresh run:
	/// tells the user which apps were re-signed and that they need to
	/// tap Install in the Library to install the refreshed copies.
	/// Silent when nothing was due.
	func notifyRefreshFinished(report: AutoRefreshReport) {
		guard !report.refreshedAppNames.isEmpty || !report.failed.isEmpty else { return }
		
		let content = UNMutableNotificationContent()
		if report.failed.isEmpty {
			content.title = .localized("Apps refreshed")
			content.body = .localized("Open the Library and install the refreshed apps.")
		} else if report.refreshedAppNames.isEmpty {
			content.title = .localized("Auto-refresh failed")
			content.body = .localized("Open the app and renew your certificate.")
		} else {
			content.title = .localized("Some apps refreshed")
			content.body = .localized("Open the Library and install the refreshed apps.")
		}
		content.sound = .default
		
		let request = UNNotificationRequest(
			identifier: "feather.auto-refresh.\(Int(Date().timeIntervalSince1970))",
			content: content,
			trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
		)
		UNUserNotificationCenter.current().add(request)
	}

	private func _reminderID(for uuid: String, daysBefore: Int) -> String {
		"feather.cert-expiry.\(uuid).\(daysBefore)d"
	}
}
