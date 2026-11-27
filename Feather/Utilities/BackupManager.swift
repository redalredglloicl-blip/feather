//  BackupManager.swift
//  Zenith
//
//  Zenith v2.12, ITEM 5 — Backup original before modding.
//
//  Keeps a copy of the original IPA so the user can restore it if a
//  mod breaks the app. Two sources, both taken BEFORE anything is
//  modified:
//
//  1. `backupIPAFile` — the byte-identical original .ipa, taken in
//     AppFileHandler.copy(), before extract() touches anything.
//  2. `backupAppDirectory` — the untouched .app re-zipped as
//     Payload/<name>.app, taken in SigningHandler.copy(), before
//     modify() runs (injection, custom name, file removal, ...).
//     This is the hook that covers every signing/modification path,
//     because all of them go through SigningHandler.copy -> modify.
//
//  Both hooks are gated on `backupBeforeModding` — the toggle on
//  the signing screen (BackupOriginalRowView, "التعديل" item 7).
//  It is ON by default. A backup failure never blocks signing or
//  importing: both hooks swallow the failure and carry on.
//
//  Storage: Documents/ZenithBackups/<name>[--<version>]--<date>.ipa.
//  A backup is NEVER deleted by the app — only `delete(_:)`, called
//  from the user's Delete tap in the Backups list, removes one.
//  Dedup: same app + same version (nil matches only nil) + same
//  byte size is the same backup, so re-signing the same version
//  does not pile up copies. One app version keeps at most two
//  backups: the byte-identical IPA and the re-zipped Payload.
//
//  Restore re-imports the backup IPA through the normal import
//  flow (Zenith.handlePackageFile), so it lands in the Library as
//  an imported (unsigned) app and the user signs it again from
//  there. The backup file itself is never touched by a restore:
//  handlePackageFile copies it into its own temp work dir.

import Foundation
import Combine
import Zip

// MARK: - Model
struct ZenithBackup: Identifiable, Hashable {
	var id: String { fileURL.path }
	let fileName: String
	let appName: String
	let version: String?
	let date: Date
	let sizeBytes: Int64
	let fileURL: URL
}

// MARK: - Class
final class BackupManager: ObservableObject {
	static let shared = BackupManager()
	
	/// Home of the backups. Documents, not Caches: a backup must
	/// survive restarts and storage pressure.
	static var backupsDirectory: URL {
		URL.documentsDirectory.appendingPathComponent("ZenithBackups", isDirectory: true)
	}
	
	@Published private(set) var backups: [ZenithBackup] = []
	
	/// Zenith v2.12 item 5: the signing-screen toggle ("save the
	/// original copy before modding"). ON by default; both backup
	/// hooks read this flag.
	@Published var backupBeforeModding: Bool = UserDefaults.standard.object(forKey: "Zenith.backupBeforeModding") as? Bool ?? true {
		didSet { UserDefaults.standard.set(backupBeforeModding, forKey: "Zenith.backupBeforeModding") }
	}
	
	private init() {
		refresh()
	}
	
	// MARK: - List
	
	func refresh() {
		let list = _scanBackups()
		DispatchQueue.main.async {
			self.backups = list
		}
	}
	
	/// The newest backup for this app: same name, and the same
	/// version when the backup records one (an import-time backup
	/// has no version — it still counts). Used by the signing
	/// screen's status line.
	func latestBackup(appName: String?, appVersion: String?) -> ZenithBackup? {
		guard let rawName = appName, !rawName.isEmpty else { return nil }
		let name = _sanitized(rawName)
		let version = appVersion.map { _sanitized($0) }.flatMap { $0.isEmpty ? nil : $0 }
		return backups.first { entry in
			guard entry.appName == name else { return false }
			if let version { return entry.version == nil || entry.version == version }
			return true
		}
	}
	
	// MARK: - Backup
	
	/// Byte-identical copy of the original .ipa file. Call BEFORE
	/// the file is extracted or modified. Returns the backup URL,
	/// or an existing identical backup, or nil when the toggle is
	/// off or the copy failed. Never throws.
	@discardableResult
	func backupIPAFile(at ipaURL: URL, displayName: String) -> URL? {
		guard backupBeforeModding else { return nil }
		// A file that already lives in the backups dir — e.g. a
		// backup being restored — needs no second copy of itself.
		guard ipaURL.deletingLastPathComponent().path != Self.backupsDirectory.path else { return nil }
		let fileManager = FileManager.default
		guard let size = (try? fileManager.attributesOfItem(atPath: ipaURL.path)[.size] as? NSNumber)?.int64Value else {
			return nil
		}
		let name = _sanitized(displayName)
		if let existing = _existingBackup(appName: name, version: nil, size: size) {
			return existing.fileURL
		}
		do {
			try fileManager.createDirectoryIfNeeded(at: Self.backupsDirectory)
			let destination = _destinationURL(appName: name, version: nil)
			try fileManager.copyItem(at: ipaURL, to: destination)
			refresh()
			return destination
		} catch {
			print("[BackupManager] IPA backup failed: \(error.localizedDescription)")
			return nil
		}
	}
	
	/// Re-zips the untouched .app directory as Payload/<name>.app
	/// and stores it as an .ipa. Call BEFORE modify() runs.
	/// Returns the backup URL, or an existing identical backup,
	/// or nil when the toggle is off or the zip failed. Never
	/// throws, so signing is never blocked by a backup failure.
	func backupAppDirectory(_ appURL: URL, appName: String?, appVersion: String?) async -> URL? {
		guard backupBeforeModding else { return nil }
		let fileManager = FileManager.default
		let name = _sanitized(appName ?? appURL.deletingPathExtension().lastPathComponent)
		let version = appVersion.map { _sanitized($0) }.flatMap { $0.isEmpty ? nil : $0 }
		let workDir = fileManager.temporaryDirectory
			.appendingPathComponent("ZenithBackup_\(UUID().uuidString)", isDirectory: true)
		let payloadDir = workDir.appendingPathComponent("Payload", isDirectory: true)
		let appCopy = payloadDir.appendingPathComponent(appURL.lastPathComponent)
		do {
			try fileManager.createDirectory(at: payloadDir, withIntermediateDirectories: true)
			try fileManager.copyItem(at: appURL, to: appCopy)
			let zipURL = workDir.appendingPathComponent("Backup.zip")
			try await Zip.zipFiles(
				paths: [payloadDir],
				zipFilePath: zipURL,
				password: nil,
				compression: ZipCompression.allCases[ArchiveHandler.getCompressionLevel()],
				progress: { _ in }
			)
			let size = (try fileManager.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.int64Value ?? 0
			if let existing = _existingBackup(appName: name, version: version, size: size) {
				try? fileManager.removeItem(at: workDir)
				return existing.fileURL
			}
			try fileManager.createDirectoryIfNeeded(at: Self.backupsDirectory)
			let destination = _destinationURL(appName: name, version: version)
			try fileManager.moveItem(at: zipURL, to: destination)
			try? fileManager.removeItem(at: workDir)
			refresh()
			return destination
		} catch {
			print("[BackupManager] app backup failed: \(error.localizedDescription)")
			try? fileManager.removeItem(at: workDir)
			return nil
		}
	}
	
	// MARK: - Restore / Delete
	
	/// Re-imports the backup IPA through the normal import flow:
	/// it appears in the Library as an imported (unsigned) app,
	/// ready to sign again. The backup file itself is untouched —
	/// handlePackageFile copies it into its own temp work dir.
	func restore(_ backup: ZenithBackup) {
		Zenith.handlePackageFile(backup.fileURL) { _ in }
	}
	
	/// The ONLY place a backup is deleted: the user's Delete tap
	/// in the Backups list. Nothing else in the app removes one.
	func delete(_ backup: ZenithBackup) {
		try? FileManager.default.removeItem(at: backup.fileURL)
		refresh()
	}
	
	// MARK: - Helpers
	
	private func _scanBackups() -> [ZenithBackup] {
		let fileManager = FileManager.default
		guard let urls = try? fileManager.contentsOfDirectory(
			at: Self.backupsDirectory,
			includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
			options: [.skipsHiddenFiles]
		) else { return [] }
		return urls
			.filter { $0.pathExtension.lowercased() == "ipa" }
			.compactMap { url -> ZenithBackup? in
				guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
				let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
				let date = (attributes[.creationDate] as? Date)
					?? (attributes[.modificationDate] as? Date)
					?? Date.distantPast
				let (name, version) = Self._parseFileName(url.deletingPathExtension().lastPathComponent)
				return ZenithBackup(
					fileName: url.lastPathComponent,
					appName: name,
					version: version,
					date: date,
					sizeBytes: size,
					fileURL: url
				)
			}
			.sorted { $0.date > $1.date }
	}
	
	private func _existingBackup(appName: String, version: String?, size: Int64) -> ZenithBackup? {
		_scanBackups().first {
			$0.appName == appName && $0.version == version && $0.sizeBytes == size
		}
	}
	
	private func _destinationURL(appName: String, version: String?) -> URL {
		var parts = [appName]
		if let version { parts.append(version) }
		parts.append(Self._timestamp())
		return Self.backupsDirectory
			.appendingPathComponent(parts.joined(separator: "--"))
			.appendingPathExtension("ipa")
	}
	
	/// "<name>--<version>--<timestamp>" or "<name>--<timestamp>".
	/// The name/version are sanitized so "--" can never occur
	/// inside them, which keeps this split unambiguous.
	private static func _parseFileName(_ fileName: String) -> (String, String?) {
		let parts = fileName.components(separatedBy: "--")
		if parts.count >= 3 {
			return (parts[0], parts[1].isEmpty ? nil : parts[1])
		}
		return (parts[0], nil)
	}
	
	private static func _timestamp() -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		return formatter.string(from: Date())
	}
	
	/// File-safe: only alphanumerics, "-" and "." survive; runs
	/// of "-" collapse to one, so "--" stays a separator.
	private func _sanitized(_ string: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
		var cleaned = string.unicodeScalars
			.map { allowed.contains($0) ? String($0) : "-" }
			.joined()
		while cleaned.contains("--") {
			cleaned = cleaned.replacingOccurrences(of: "--", with: "-")
		}
		cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
		if cleaned.isEmpty { cleaned = "app" }
		if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)) }
		return cleaned
	}
}
