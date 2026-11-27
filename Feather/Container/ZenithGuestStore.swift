//
//  ZenithGuestStore.swift
//  Zenith
//
//  Phase 1 container — where guest bundles live on disk.
//
//  Layout (LiveContainer model, adapted):
//    Documents/Applications/<bundle-id>.app   — the guest bundle
//    Documents/Applications/<bundle-id>.app/LCAppInfo.plist
//    Documents/Data/Application/<data-uuid>/  — guest data dir
//  The folder name is the sanitized bundle identifier, exactly
//  like LC (`"\(bundleIdentifier).app"`, timestamp-suffixed on
//  conflict). The Library record stays the existing `Imported`
//  row. NOTE (additive-only re-scope): v2.13 readers do NOT
//  resolve a converted guest — Storage.getAppDirectory still
//  returns the Unsigned/<uuid> path, which the importer
//  keeps on success (proof decision), so icon / file size /
//  info fall back for guest rows (see Worker H report). Guest
//  lookup lives ONLY here (guestBundleURL / isGuest), used by
//  the launcher and the passport proof action — never by
//  v2.13 code.
//

import Foundation

// MARK: - Guest store
enum ZenithGuestStore {

	/// Posted (with the app's uuid in userInfo) when an import
	/// finishes: the Library and passport rows re-read guest
	/// state (the Core Data row itself does not change, so the
	/// fetch request would not refresh on its own).
	static let didImportGuestNotification = Notification.Name("Zenith.guestImported")

	/// Documents/Applications — home of guest bundles.
	static var applicationsDirectory: URL {
		URL.documentsDirectory.appendingPathComponent("Applications", isDirectory: true)
	}

	/// Documents/Data/Application — home of guest data dirs.
	static var dataRootDirectory: URL {
		URL.documentsDirectory
			.appendingPathComponent("Data", isDirectory: true)
			.appendingPathComponent("Application", isDirectory: true)
	}

	/// Data dir for one guest (created at import; the loader
	/// owns what goes inside it).
	static func dataDirectory(for dataUUID: String) -> URL {
		dataRootDirectory.appendingPathComponent(dataUUID, isDirectory: true)
	}

	/// Folder name for a bundle identifier, LC-style.
	/// Bundle identifiers are already `[A-Za-z0-9.-]`, so the
	/// sanitizer is a no-op in practice — it only guards
	/// against a hostile identifier smuggling a path separator.
	static func folderName(forBundleIdentifier identifier: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
		let sanitized = identifier.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
		return String(sanitized) + ".app"
	}

	/// Folder name that does not collide yet: on conflict LC
	/// appends a timestamp (`<id>_<time>.app`).
	static func uniqueFolderName(forBundleIdentifier identifier: String) -> String {
		let base = folderName(forBundleIdentifier: identifier)
		guard FileManager.default.fileExists(atPath: applicationsDirectory.appendingPathComponent(base).path) else {
			return base
		}
		let stem = String(base.dropLast(4)) // strip ".app"
		return "\(stem)_\(Int(CFAbsoluteTimeGetCurrent())).app"
	}

	/// The guest bundle for a Library app, or nil when the app
	/// was never converted to a guest. Direct hit first
	/// (`<id>.app`), then a scan matching LCAppInfo.plist's
	/// LCOriginalBundleIdentifier (covers timestamp-suffixed
	/// folders from a conflicted import).
	static func guestBundleURL(for app: AppInfoPresentable) -> URL? {
		guard let identifier = app.identifier, !identifier.isEmpty else { return nil }
		let fileManager = FileManager.default
		let direct = applicationsDirectory.appendingPathComponent(folderName(forBundleIdentifier: identifier))
		if fileManager.fileExists(atPath: direct.path) {
			return direct
		}
		guard
			let children = try? fileManager.contentsOfDirectory(
				at: applicationsDirectory,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			)
		else {
			return nil
		}
		for child in children where child.pathExtension == "app" {
			let info = ZenithGuestInfo(bundleURL: child)
			if info.originalBundleIdentifier == identifier {
				return child
			}
		}
		return nil
	}

	/// True when a bundle identifier already has a guest bundle
	/// on disk (used by the fresh-IPA path, which has no Library
	/// record to probe yet).
	static func isBundleIdentifierGuest(_ identifier: String) -> Bool {
		guard !identifier.isEmpty else { return false }
		let direct = applicationsDirectory.appendingPathComponent(folderName(forBundleIdentifier: identifier))
		if FileManager.default.fileExists(atPath: direct.path) {
			return true
		}
		guard
			let children = try? FileManager.default.contentsOfDirectory(
				at: applicationsDirectory,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			)
		else {
			return false
		}
		for child in children where child.pathExtension == "app" {
			if ZenithGuestInfo(bundleURL: child).originalBundleIdentifier == identifier {
				return true
			}
		}
		return false
	}

	/// True when the app has a guest bundle on disk.
	static func isGuest(_ app: AppInfoPresentable) -> Bool {
		guestBundleURL(for: app) != nil
	}

	/// The guest model for a Library app, or nil when it is not
	/// a guest.
	static func guestInfo(for app: AppInfoPresentable) -> ZenithGuestInfo? {
		guard let bundleURL = guestBundleURL(for: app) else { return nil }
		return ZenithGuestInfo(bundleURL: bundleURL)
	}
}
