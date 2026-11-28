//
//  Server.swift
//  zenith
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR ZENITH
//

import Foundation
import Combine
import Vapor
import NIOSSL
import NIOTLS
import OSLog
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	
	var packageUrl: URL?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) throws {
		self.app = app
		self.viewModel = viewModel
		try _setup()
		try _configureRoutes()
		try _server?.server.start()
		_needsShutdown = true
	}
	
	deinit {
		_shutdownServer()
	}
	
	private func _setup() throws {
		self._server = try? setupApp(port: port)
	}
		
	private func _configureRoutes() throws {
		_server?.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case plistEndpoint.path:
				self._updateStatus(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				guard let packageUrl = packageUrl else {
					return Response(status: .notFound)
				}
				
				self._updateStatus(.sendingPayload)
				
				return req.fileio.streamFile(
					at: packageUrl.path
				) { result in
					switch result {
					case .success:
						self._updateStatus(.installing)
					case .failure(let error):
						self._updateStatus(.broken(error))
					}

				}
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	private func _shutdownServer() {
		guard _needsShutdown else { return }
		
		_needsShutdown = false
		_server?.server.shutdown()
		_server?.shutdown()
	}
	
	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}
		
	func getServerMethod() -> Int {
		// Zenith v2.15: "Fully Local" (0) serves the manifest over
		// https with the backloop.dev TLS pack. That pack is not
		// shipped in the app and the copy on backloop.dev expired
		// 2026-10-29, so mode 0 can never serve a manifest iOS
		// trusts: itms-services fails silently and the install hangs
		// at "Ready" with no prompt and no home-screen icon. Honour
		// mode 0 only while a valid (unexpired) pack is actually on
		// disk; otherwise fall back to "Semi Local" (1), whose
		// manifest comes from palera.in over real https and whose IPA
		// comes from the local server. Fresh installs default to 1.
		let stored = UserDefaults.standard.object(forKey: "Zenith.serverMethod") as? Int ?? 1
		if stored == 0, !Self.hasValidTLSPack() {
			return 1
		}
		return stored
	}
	
	func getIPFix() -> Bool {
		UserDefaults.standard.bool(forKey: "Zenith.ipFix")
	}
}

// MARK: - Install session keeper (Zenith v2.21)
/// Owns the live install server OUTSIDE the view hierarchy, so
/// the download survives anything that tears the install sheet
/// down mid-install.
///
/// Proven failure (2.20): the sheet's @StateObject was the
/// server's ONLY owner, so any teardown of the sheet — the root
/// view swapping to OfflineBlockView on a brief isOffline flip,
/// the forced-update screen, a dismiss — deallocated the server
/// while installd was still fetching the IPA. The download then
/// stalled at ~50% (overallProgress is (install + package) / 2
/// and install stays 0 until the whole IPA is served), the home
/// screen kept a white placeholder icon, and tapping it showed
/// the integrity alert. The 2.20 fixes (no swipe-dismiss while
/// in flight, audio kept on .broken) never covered this: they
/// only guarded the sheet itself.
///
/// The session also holds the two background-survival mechanisms
/// the install needs while Zenith is backgrounded: the
/// silent-audio keep-alive (a second, sheet-independent hold,
/// so the sheet's onDisappear cannot stop it) and a
/// beginBackgroundTask (the sanctioned short-task grant — the
/// local transfer takes seconds). Either one alone is fragile;
/// together they cover an audio interruption and a task expiry.
///
/// Lifetime: begin() when the install sheet appears, end() as
/// soon as the install reaches .completed. A .broken status does
/// NOT end the session (v2.23) — installd may still retry/resume
/// against the live server. A 10-minute grace end bounds the
/// session if the sheet (and its poll) is gone and no terminal
/// status ever arrives — a local install finishes in well under
/// that.
final class InstallSessionManager {
	static let shared = InstallSessionManager()

	private var _server: ServerInstaller?
	#if !targetEnvironment(macCatalyst)
	private var _backgroundTask: UIBackgroundTaskIdentifier = .invalid
	#endif
	private var _statusCancellable: AnyCancellable?
	private var _graceTask: Task<Void, Never>?
	/// Whether this session holds its own audio keep-alive.
	/// Tracked separately from the refcount so begin() never
	/// eats the sheet's hold (v2.23) and end() never stops audio
	/// it does not hold.
	private var _audioHeld = false

	private init() {}

	/// Keep `server` (and the process) alive for this install.
	/// Ends any previous session first (without touching audio).
	/// Call on the main thread.
	func begin(server: ServerInstaller, viewModel: InstallerStatusViewModel) {
		// Zenith v2.23: tear down a previous session WITHOUT
		// touching audio. The old begin() called end(), which
		// stopped the audio — eating the sheet's onAppear hold
		// (count 1→0, engine stopped) and then restarting it, a
		// stop→restart cycle on every sheet appearance. If that
		// restart threw, the refcount stayed 1 with a dead engine
		// (phantom hold) and the process suspended when the
		// itms-services link backgrounded Zenith.
		_endSessionWithoutAudio()
		_server = server
		#if !targetEnvironment(macCatalyst)
		if !_audioHeld {
			BackgroundAudioManager.shared.start()
			_audioHeld = true
		}
		if !BackgroundAudioManager.shared.ensureEngineRunning() {
			Logger.misc.error("Install session: audio keep-alive engine is not running after start.")
		}
		_beginBackgroundTask()
		#endif
		_statusCancellable = viewModel.$status
			.receive(on: DispatchQueue.main)
			.sink { [weak self] status in
				switch status {
				case .completed:
					self?.end()
				case .broken:
					// Zenith v2.23: do NOT end the session on
					// .broken. The server must survive so installd
					// can retry/resume the payload fetch — ending
					// here destroyed the server on a transient
					// stall or a slow prompt confirmation, and the
					// retry hit a dead server. The 10-minute grace
					// task below bounds the session.
					break
				default:
					break
				}
			}
		_graceTask = Task.detached { [weak self] in
			try? await Task.sleep(nanoseconds: 600_000_000_000)
			guard !Task.isCancelled else { return }
			await MainActor.run { self?.end() }
		}
	}

	/// Release the server, the background task and the audio
	/// hold. Idempotent; safe to call when no session is active.
	/// Call on the main thread.
	func end() {
		_endSessionWithoutAudio()
		#if !targetEnvironment(macCatalyst)
		if _audioHeld {
			BackgroundAudioManager.shared.stop()
			_audioHeld = false
		}
		#endif
	}

	/// Release the server, the background task, the status sink
	/// and the grace task — but NOT the audio hold. begin() uses
	/// this so a previous session's teardown never eats the
	/// sheet's (or this session's) audio hold.
	private func _endSessionWithoutAudio() {
		_statusCancellable?.cancel()
		_statusCancellable = nil
		_graceTask?.cancel()
		_graceTask = nil
		#if !targetEnvironment(macCatalyst)
		_endBackgroundTask()
		#endif
		_server = nil
	}

	#if !targetEnvironment(macCatalyst)
	private func _beginBackgroundTask() {
		guard _backgroundTask == .invalid else { return }
		_backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ZenithInstall") { [weak self] in
			// Zenith v2.23: this ~30s grant expired — give the old
			// task back, then immediately begin a fresh one while
			// the session is still active, so a live task covers
			// the whole session in ~30s slices. The old code only
			// ended the task here, so by the time installd fetched
			// the IPA no task was live. Do not re-begin once the
			// session has ended (_server nil).
			guard let self else { return }
			self._endBackgroundTask()
			if self._server != nil {
				self._beginBackgroundTask()
			}
		}
	}

	private func _endBackgroundTask() {
		guard _backgroundTask != .invalid else { return }
		UIApplication.shared.endBackgroundTask(_backgroundTask)
		_backgroundTask = .invalid
	}
	#endif
}
