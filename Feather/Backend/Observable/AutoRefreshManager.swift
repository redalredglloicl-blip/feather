
//
//  AutoRefreshManager.swift
//  Feather
//
//  Background auto-refresh, modelled on SideStore's approach and adapted
//  to what Feather already has:
//
//  * Due apps: signed apps whose certificate expires within 3 days
//    (free certificates last 7 days, so refresh every few days —
//    never on the last day).
//  * Fresh certificate: fetched with the Apple ID session saved in the
//    Keychain by an earlier sign-in (AppleIDAuthManager) — no password,
//    no UI. Without a stored session there is nothing to refresh with,
//    and the user is reminded by a local notification instead.
//  * Re-sign: the existing SigningHandler + embedded Zsign, exactly the
//    same path the manual Sign button uses. The re-signed bundle replaces
//    the old bundle in place, so the Library entry stays the same.
//  * Reinstall: iOS cannot install an app silently from the background.
//    The refreshed bundle is ready in the Library; the user taps the
//    existing Install button (or the notification) to install it.
//    Background work therefore does re-sign + notify, never install.
//  * Background time: a BGAppRefreshTask (registered in the AppDelegate)
//    + the existing silent-audio manager to stretch the time iOS gives us.
//    Background execution is best-effort: iOS decides when to run it.
//  * Self-refresh: FOREGROUND ONLY, behind an explicit confirmation.
//    Re-signing Feather itself and installing the new copy over the old
//    one is the most dangerous step in this file — any failure could
//    leave the user with no app at all. It is therefore never attempted
//    in the background, never attempted when any other app failed, and
//    it installs only through the AFC pairing path (the server path
//    refuses self-install by design). When AFC is not available the
//    freshly signed IPA is saved to Archives and the user installs it
//    with SideStore/ESign instead.
//
//  Honest limits: none of this has run on a real device from this
//  workspace. The background task, the re-sign swap and self-refresh
//  are only proven by a real build + device test (see FEATHER_MOD_PLAN.md §6).

import Foundation
import BackgroundTasks
import CoreData
import IDeviceSwift
import Zip

// MARK: - Errors

enum AutoRefreshError: Error, LocalizedError {
	case noStoredSession
	case noCertificate
	case resignFailed(appName: String, underlying: Error)
	case selfRefreshFailed(underlying: Error)
	
	var errorDescription: String? {
		switch self {
		case .noStoredSession:
			return "No saved Apple ID session. Sign in once from Certificates to enable auto-refresh."
		case .noCertificate:
			return "Could not fetch a fresh certificate."
		case .resignFailed(let name, let error):
			return "Could not re-sign \(name): \(error.localizedDescription)"
		case .selfRefreshFailed(let error):
			return "Could not refresh Feather itself: \(error.localizedDescription)"
		}
	}
}

// MARK: - Report

struct AutoRefreshReport {
	var refreshedAppNames: [String] = []
	var failed: [(name: String, error: Error)] = []
	var newCertificate: CertificatePair?
	var selfRefresh: SelfRefreshOutcome?
	
	enum SelfRefreshOutcome {
		/// Installed over itself through the AFC pairing path.
		case installed
		/// Signed IPA saved to Archives; the user installs it by hand.
		case ipaReady(URL)
		/// Not attempted (background run, or AFC unavailable and the
		/// user has not confirmed a foreground self-refresh).
		case notAttempted
	}
}

// MARK: - Manager

@MainActor
final class AutoRefreshManager {
	static let shared = AutoRefreshManager()
	
	/// Refresh apps whose certificate expires within this window.
	static let dueWithin: TimeInterval = 3 * 86400
	/// Also re-sign apps that have not been re-signed for this long,
	/// even if the certificate still has time (keeps the 7-day clock fresh).
	static let resignIfOlderThan: TimeInterval = 4 * 86400
	
	static var backgroundTaskIdentifier: String {
		"\(Bundle.main.bundleIdentifier!).autoRefresh"
	}
	
	private init() {}
	
	// MARK: - Due apps
	
	/// Signed apps that should be re-signed now, soonest expiry first.
	func dueApps() -> [Signed] {
		let all = _allSignedApps()
		let now = Date()
		return all
			.filter { app in
				guard let cert = app.certificate, let expiration = cert.expiration else {
					return false
				}
				if expiration.timeIntervalSince(now) <= Self.dueWithin {
					return true
				}
				if let signedDate = app.date, now.timeIntervalSince(signedDate) >= Self.resignIfOlderThan {
					return true
				}
				return false
			}
			.sorted {
				($0.certificate?.expiration ?? .distantFuture) < ($1.certificate?.expiration ?? .distantFuture)
			}
	}
	
	// MARK: - Foreground refresh
	
	/// Re-signs every due app with a fresh free certificate fetched
	/// through the stored Apple ID session. Returns a report; partial
	/// failure is normal and is reported per app, never hidden.
	func refreshDueApps() async -> AutoRefreshReport {
		var report = AutoRefreshReport()
		
		let due = dueApps()
		guard !due.isEmpty else {
			return report
		}
		
		let freshCertificate: CertificatePair
		do {
			freshCertificate = try await AppleIDAuthManager.shared.refreshCertificateWithStoredSession()
		} catch {
			for app in due {
				report.failed.append((name: app.name ?? "", error: error))
			}
			return report
		}
		report.newCertificate = freshCertificate
		
		for app in due {
			do {
				try await _resign(app, with: freshCertificate)
				report.refreshedAppNames.append(app.name ?? "")
			} catch {
				report.failed.append((name: app.name ?? "", error: error))
			}
		}
		
		if let cert = report.newCertificate {
			NotificationManager.shared.scheduleExpiryReminders(for: cert)
		}
		NotificationManager.shared.notifyRefreshFinished(report: report)
		return report
	}
	
	// MARK: - Self-refresh (foreground only, user-confirmed)
	
	/// Re-signs Feather's own bundle with a fresh free certificate.
	/// Only call from the foreground behind an explicit confirmation.
	/// Returns `.installed` when the AFC pairing path installed the new
	/// copy over the old one, or `.ipaReady` with the saved IPA path
	/// when AFC is unavailable (the user installs it with SideStore/ESign).
	func refreshSelf() async throws -> AutoRefreshReport.SelfRefreshOutcome {
		let freshCertificate = try await AppleIDAuthManager.shared.refreshCertificateWithStoredSession()
		
		let ipaURL: URL
		do {
			ipaURL = try await _prepareSelfRefreshIPA(with: freshCertificate)
		} catch {
			throw AutoRefreshError.selfRefreshFailed(underlying: error)
		}
		
		// The server install path refuses self-install by design
		// (InstallPreviewView); only the AFC pairing path can install
		// Feather over itself, and it needs a pairing file + VPN.
		guard UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1 else {
			return .ipaReady(ipaURL)
		}
		
		do {
			let viewModel = InstallerStatusViewModel(isIdevice: true)
			let proxy = InstallationProxy(viewModel: viewModel)
			try await proxy.install(at: ipaURL, suspend: true)
			return .installed
		} catch {
			// The signed IPA is still saved in Archives, so a failed
			// install never leaves the user with nothing: the old copy
			// keeps running and the new IPA can be installed by hand.
			return .ipaReady(ipaURL)
		}
	}
	
	// MARK: - Background
	
	func registerBackgroundRefresh() {
		BGTaskScheduler.shared.register(
			forTaskWithIdentifier: Self.backgroundTaskIdentifier,
			using: nil
		) { task in
			guard let task = task as? BGAppRefreshTask else { return }
			// Re-schedule the next run first, so a crash still leaves
			// a future refresh scheduled.
			self.scheduleBackgroundRefresh()
			task.expirationHandler = {
				task.setTaskCompleted(success: false)
			}
			Task {
				let report = await self._runBackgroundRefresh()
				task.setTaskCompleted(success: report.failed.isEmpty)
			}
		}
	}
	
	func scheduleBackgroundRefresh() {
		registerBackgroundRefresh()
		let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
		request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 3600)
		try? BGTaskScheduler.shared.submit(request)
	}
	
	private func _runBackgroundRefresh() async -> AutoRefreshReport {
		// Silent audio stretches the background time iOS grants us.
		// It is best-effort: iOS may still cut us off at any moment.
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.start()
		defer { BackgroundAudioManager.shared.stop() }
		#endif
		
		// Never self-refresh from the background: if anything goes
		// wrong there is no user present to recover, and the app could
		// be left uninstalled. Only other apps are refreshed here.
		return await refreshDueApps()
	}
	
	// MARK: - Re-sign one app (in place)
	
	private func _resign(_ app: Signed, with cert: CertificatePair) async throws {
		let beforeUUIDs = Set(_allSignedApps().compactMap(\.uuid))
		
		let handler = SigningHandler(app: app, options: OptionsManager.shared.options)
		handler.appCertificate = cert
		do {
			// File + signing work off the main actor, like the manual
			// Sign button (FR.signPackageFile uses Task.detached).
			try await Task.detached {
				try await handler.copy()
				try await handler.modify()
				try? await handler.clean()
			}.value
		} catch {
			throw AutoRefreshError.resignFailed(appName: app.name ?? "", underlying: error)
		}
		
		// SigningHandler always creates a NEW Signed record. Swap its
		// freshly signed .app into the OLD record's directory, delete
		// the new record, and point the old record at the new cert.
		let fresh = _allSignedApps().first(where: {
			guard let uuid = $0.uuid else { return false }
			return !beforeUUIDs.contains(uuid)
		})
		guard
			let fresh,
			let freshAppDir = Storage.shared.getAppDirectory(for: fresh),
			let oldAppDir = Storage.shared.getAppDirectory(for: app)
		else {
			throw AutoRefreshError.resignFailed(
				appName: app.name ?? "",
				underlying: NSError(domain: "Feather.AutoRefresh", code: 1, userInfo: [
					NSLocalizedDescriptionKey: "Signed bundle not found after re-signing."
				])
			)
		}
		
		do {
			try FileManager.default.removeItem(at: oldAppDir)
			try FileManager.default.moveItem(at: freshAppDir, to: oldAppDir)
		} catch {
			throw AutoRefreshError.resignFailed(appName: app.name ?? "", underlying: error)
		}
		
		// The fresh record's directory is now empty of the .app;
		// removing the record also removes that directory.
		Storage.shared.deleteApp(for: fresh)
		app.certificate = cert
		app.date = Date()
		Storage.shared.saveContext()
	}
	
	// MARK: - Self-refresh IPA
	
	private func _prepareSelfRefreshIPA(with cert: CertificatePair) async throws -> URL {
		let fileManager = FileManager.default
		let workDir = fileManager.temporaryDirectory
			.appendingPathComponent("FeatherSelfRefresh_\(UUID().uuidString)", isDirectory: true)
		let payloadDir = workDir.appendingPathComponent("Payload", isDirectory: true)
		let appCopy = payloadDir.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
		
		try fileManager.createDirectory(at: payloadDir, withIntermediateDirectories: true)
		try fileManager.copyItem(at: Bundle.main.bundleURL, to: appCopy)
		
		let zsign = ZsignHandler(appUrl: appCopy, options: OptionsManager.shared.options, cert: cert)
		try await zsign.disinject()
		try await zsign.sign()
		if let error = zsign.hadError {
			throw error
		}
		
		let zipURL = workDir.appendingPathComponent("Feather.zip")
		let ipaURL = workDir.appendingPathComponent("Feather.ipa")
		try await Zip.zipFiles(
			paths: [payloadDir],
			zipFilePath: zipURL,
			password: nil,
			compression: ZipCompression.allCases[ArchiveHandler.getCompressionLevel()],
			progress: { _ in }
		)
		try fileManager.moveItem(at: zipURL, to: ipaURL)
		
		let version = Bundle.main.version
		let dest = fileManager.archives.appendingPathComponent(
			"Feather_\(version)_\(Int(Date().timeIntervalSince1970)).ipa"
		)
		try fileManager.createDirectoryIfNeeded(at: fileManager.archives)
		try? fileManager.moveItem(at: ipaURL, to: dest)
		return dest
	}
	
	// MARK: - Helpers
	
	private func _allSignedApps() -> [Signed] {
		(try? Storage.shared.context.fetch(Signed.fetchRequest())) ?? []
	}
}
