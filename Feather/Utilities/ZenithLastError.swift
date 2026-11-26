//
//  ZenithLastError.swift
//  Feather
//
//  Zenith v2.2: tiny last-error store for the Help Center diagnostics.
//  Sign/install error paths record the real error text here (UserDefaults,
//  local only); the Help Center shows it back so the user can read
//  exactly what failed last, instead of guessing.
//

import Foundation

// MARK: - Store
enum ZenithLastError {
	private static let _messageKey = "Zenith.lastError"
	private static let _dateKey = "Zenith.lastErrorDate"

	/// The last recorded error, with when it happened. Nil when no
	/// error has been recorded (or the record was cleared).
	static var last: (message: String, date: Date?)? {
		guard let message = UserDefaults.standard.string(forKey: _messageKey) else {
			return nil
		}
		let date = UserDefaults.standard.object(forKey: _dateKey) as? Date
		return (message, date)
	}

	/// Records an error exactly as the system reported it.
	static func record(_ error: Error) {
		record(message: error.localizedDescription)
	}

	/// Records a plain error message.
	static func record(message: String) {
		UserDefaults.standard.set(message, forKey: _messageKey)
		UserDefaults.standard.set(Date(), forKey: _dateKey)
	}

	/// Clears the record, e.g. after a successful sign.
	static func clear() {
		UserDefaults.standard.removeObject(forKey: _messageKey)
		UserDefaults.standard.removeObject(forKey: _dateKey)
	}
}
