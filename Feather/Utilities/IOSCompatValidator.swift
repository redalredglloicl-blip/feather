//
//  IOSCompatValidator.swift
//  Zenith
//
//  Zenith v2.2: iOS-compatibility check, run before signing. Reads the
//  IPA's MinimumOSVersion from its own Info.plist and compares it with
//  the device iOS. Pure validator — it never signs, never modifies
//  anything, and never blocks on its own: the caller decides whether
//  to warn, skip, or let the user proceed anyway.
//

import Foundation
import UIKit

// MARK: - Validator
enum IOSCompatValidator {
	/// Result of checking one app against this device.
	enum Check {
		/// The app runs on this iOS (or states no minimum).
		case compatible(minimumOS: String?)
		/// The bundle has no readable Info.plist / MinimumOSVersion,
		/// so no verdict is possible — never treated as a failure.
		case unknown
		/// The app needs a newer iOS than this device runs.
		case requiresNewer(minimumOS: String, deviceOS: String)
	}

	/// Reads MinimumOSVersion from the app bundle's Info.plist and
	/// compares it with `UIDevice.current.systemVersion`.
	static func check(app: AppInfoPresentable) -> Check {
		guard let minimumOS = _minimumOSVersion(for: app) else {
			return .unknown
		}
		let deviceOS = UIDevice.current.systemVersion
		if _compareVersions(minimumOS, isNewerThan: deviceOS) {
			return .requiresNewer(minimumOS: minimumOS, deviceOS: deviceOS)
		}
		return .compatible(minimumOS: minimumOS)
	}

	// MARK: Private

	/// MinimumOSVersion straight from the bundle's Info.plist.
	/// `Bundle.minimumOSVersion` is the fallback for bundles whose
	/// plist cannot be read as a dictionary.
	private static func _minimumOSVersion(for app: AppInfoPresentable) -> String? {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else {
			return nil
		}
		if
			let info = NSDictionary(contentsOf: appDirectory.appendingPathComponent("Info.plist")),
			let minimumOS = info["MinimumOSVersion"] as? String,
			!minimumOS.isEmpty
		{
			return minimumOS
		}
		return Bundle(url: appDirectory)?.minimumOSVersion
	}

	/// True when `lhs` is a strictly newer version than `rhs`.
	/// Numeric per-component comparison, so "17.0" < "17.2" < "27.0"
	/// and "9.0" < "10.0" (no lexicographic traps).
	private static func _compareVersions(_ lhs: String, isNewerThan rhs: String) -> Bool {
		let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
		let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }
		let count = max(lhsParts.count, rhsParts.count)
		for index in 0..<count {
			let left = index < lhsParts.count ? lhsParts[index] : 0
			let right = index < rhsParts.count ? rhsParts[index] : 0
			if left != right {
				return left > right
			}
		}
		return false
	}
}
