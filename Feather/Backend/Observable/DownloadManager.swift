//
//  enum.swift
//  Zenith
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit.UIImpactFeedbackGenerator
import BackgroundTasks

/// Live state of one download, shown in the Downloads tab.
enum DownloadStatus {
	case downloading
	case paused
	case failed
	case completed
}

extension DownloadStatus {
	/// Stable name for the active-download record persisted to disk.
	var _persistedName: String {
		switch self {
		case .downloading: return "downloading"
		case .paused: return "paused"
		case .failed: return "failed"
		case .completed: return "completed"
		}
	}
}

/// Zenith v2.11: ObservableObject, so a row can observe the live
/// download directly (@ObservedObject) instead of mirroring each
/// @Published property into @State through onReceive — the mirror
/// could only show what its subscriptions delivered, and the row's
/// Pause/Resume button was gated on the mirrored copy.
class Download: Identifiable, ObservableObject, @unchecked Sendable {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	
	/// Real measured throughput (bytes/sec) and ETA, from live byte counts.
	@Published var speedBytesPerSec: Int64 = 0
	@Published var estimatedTimeRemaining: TimeInterval?
	@Published var status: DownloadStatus = .downloading
	@Published var errorMessage: String?
	/// True when the download runs on parallel range connections.
	@Published var isAccelerated: Bool = false
	
	/// True when the download was auto-paused because the internet
	/// dropped (or it was created while offline): it resumes itself
	/// as soon as connectivity returns. Never set for a manual
	/// pause — a download the user paused by hand is never
	/// auto-resumed. Status stays `.paused` so the existing
	/// pause/resume logic works unchanged.
	@Published var isWaitingForInternet = false
	
	/// Smoothed throughput (bytes/sec): an exponential moving
	/// average of the real measured samples, so the number on
	/// screen never jumps or collapses on one short sample. Only
	/// ever fed real measured bytes — never inflated. Time
	/// constant 2 s: alpha = 1 - exp(-elapsed / 2).
	/// Main-actor only: both transports hop to the main actor
	/// before reporting, and only _updateSpeedAndETA touches these.
	var _smoothedSpeed: Double = 0
	/// Last raw sample point feeding the EMA.
	var _emaSampleBytes: Int64 = 0
	var _emaSampleDate: Date?
	/// Smoothed ETA (seconds) actually shown, and when it was
	/// last published (at most once a second).
	var _smoothedETA: TimeInterval?
	var _lastETAPublishDate: Date?
	
	/// Feeds one real byte-count sample into the smoothed speed
	/// and ETA. Must be called on the main actor. `totalDownloaded`
	/// and `totalBytes` are the live counts; `now` is the sample
	/// time. Samples arrive at most ~4 Hz from either transport;
	/// the EMA (tau = 2 s) turns them into a stable displayed
	/// speed, and the ETA is published at most once a second,
	/// itself smoothed, so the seconds never jump wildly.
	/// Honest edges: a stalled stream decays the speed toward
	/// zero instead of freezing the last value; with no usable
	/// speed the ETA is nil (the row shows "—"), never a huge
	/// number from dividing by ~0; finished means ETA 0.
	func _updateSpeedAndETA(totalDownloaded: Int64, totalBytes: Int64, now: Date) {
		guard let lastDate = _emaSampleDate else {
			_emaSampleDate = now
			_emaSampleBytes = totalDownloaded
			return
		}
		let elapsed = now.timeIntervalSince(lastDate)
		guard elapsed >= 0.25 else { return }
		let delta = totalDownloaded - _emaSampleBytes
		_emaSampleBytes = totalDownloaded
		_emaSampleDate = now
		// A gap over 10 s means the transport was paused / stalled
		// between samples: re-seed instead of letting one stale
		// sample collapse the average.
		if elapsed > 10 {
			_smoothedSpeed = 0
			speedBytesPerSec = 0
			return
		}
		guard delta >= 0 else { return }
		let instant = Double(delta) / elapsed
		if _smoothedSpeed <= 0 {
			_smoothedSpeed = instant
		} else {
			let alpha = 1.0 - exp(-elapsed / 2.0)
			_smoothedSpeed = alpha * instant + (1.0 - alpha) * _smoothedSpeed
		}
		speedBytesPerSec = Int64(_smoothedSpeed)
		
		if totalBytes > 0, totalDownloaded >= totalBytes {
			_smoothedETA = 0
			estimatedTimeRemaining = 0
			return
		}
		// No usable speed (stalled, or barely moving): no ETA,
		// never a huge number from dividing by ~0.
		guard _smoothedSpeed >= 1024, totalBytes > 0 else {
			_smoothedETA = nil
			estimatedTimeRemaining = nil
			return
		}
		let rawETA = TimeInterval(totalBytes - totalDownloaded) / _smoothedSpeed
		// Publish the ETA at most once a second, and smooth the
		// ETA itself (alpha 0.5) so the seconds move gradually.
		if let lastPublish = _lastETAPublishDate, now.timeIntervalSince(lastPublish) < 1.0 {
			return
		}
		_lastETAPublishDate = now
		if let previous = _smoothedETA {
			_smoothedETA = 0.5 * rawETA + 0.5 * previous
		} else {
			_smoothedETA = rawETA
		}
		estimatedTimeRemaining = _smoothedETA
	}
	
	/// Active multi-connection download, if this download uses it.
	var multipart: ZenithMultipartDownload?
	
	/// True once a transport (multipart or single task) has been started
	/// for this download; guards against double-start races when a
	/// pause/resume lands while the HEAD probe is still in flight.
	var _transportStarted = false
	
	var overallProgress: Double {
		onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}
	
	var task: URLSessionDownloadTask?
	var resumeData: Data?
	
	/// Cookies captured from the in-app browser session for this
	/// download (if any): attached to every URLSession request so
	/// hosts that only serve the file to the logged-in session keep
	/// working on the retry.
	var cookies: [HTTPCookie]?
	
	/// "Cookie" header value built from `cookies` at download start:
	/// a plain string, so the browser-session cookies survive the
	/// relaunch-restore of this download (HTTPCookie objects cannot
	/// be persisted). `_cookieHeaderValue` prefers this when set.
	var cookieHeader: String?
	
	/// True when the finished file is an app package (by extension).
	/// Only .ipa files go through the install flow; anything else
	/// completes as a plain file download.
	var isIPA: Bool { (fileName as NSString).pathExtension.lowercased() == "ipa" }
	
	let id: String
	let url: URL
	var fileName: String
	let onlyArchiving: Bool
	
	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false,
		fileName: String? = nil
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		// A pasted link can end in "/" or in a bare "download" path
		// with no usable file name — never ship an empty name into
		// the flow. The name is kept exactly as given, for ANY file
		// type: no ".ipa" suffix is forced any more. (fileName is
		// var, not let: the single-task completion adopts the
		// server-suggested name, which is the real name on disk.)
		let rawName = (fileName ?? url.lastPathComponent)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		self.fileName = rawName.isEmpty ? "download" : rawName
	}
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()
	
	@Published var downloads: [Download] = []
	
	/// Finished downloads (completed or failed), newest first, kept on disk.
	@Published var history: [DownloadHistoryEntry] = []
	
	/// Zenith v2.12 item 7: "Ask to save to Files after download".
	/// OFF by default — when OFF, nothing changes: finished files
	/// just stay in the app's ZenithDownloads dir. When ON, a
	/// finished download offers the system export picker
	/// (see `fileAwaitingSave`), so the user picks where in Files
	/// the file goes — or dismisses. Never an automatic save:
	/// files can only leave the sandbox through the picker.
	@Published var askToSaveToFilesAfterDownload: Bool = UserDefaults.standard.object(forKey: "Zenith.askToSaveToFilesAfterDownload") as? Bool ?? false {
		didSet { UserDefaults.standard.set(askToSaveToFilesAfterDownload, forKey: "Zenith.askToSaveToFilesAfterDownload") }
	}
	
	/// Zenith v2.12 item 7: the finished file the Downloads tab
	/// should offer in the system export picker, or nil when no
	/// picker is pending. Set by a manual "Save to Files" tap, or
	/// automatically at completion when the toggle above is ON.
	/// The Downloads tab presents the picker for this URL and
	/// clears it (via `dismissSavePrompt`) on pick or dismiss —
	/// the file itself always stays in ZenithDownloads either way.
	@Published var fileAwaitingSave: URL?
	
	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) && $0.status != .failed }
	}
	
	/// Warn when a big download would run slower than this (bytes/sec).
	static let slowSpeedThreshold: Double = 100 * 1024
	/// Downloads bigger than this get a speed probe first.
	static let largeDownloadThreshold: Int64 = 50 * 1024 * 1024
	/// Minimum size for parallel range connections.
	static let multipartMinimumSize: Int64 = 8 * 1024 * 1024
	
	/// A real mobile-Safari user agent. Some file hosts refuse the
	/// default URLSession agent (or a HEAD with no browser agent) and
	/// the download then fails before a byte moves — every request
	/// DownloadManager makes carries this instead.
	static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
	
	/// Builds the "Cookie" header value for a download's captured
	/// browser cookies (if any), via HTTPCookie.requestHeaderFields.
	/// fileprivate (not private) so the multi-connection downloader
	/// in this same file can attach it to its part requests too.
	fileprivate func _cookieHeaderValue(for download: Download) -> String? {
		// The stored header survives a relaunch-restore, where the
		// HTTPCookie objects themselves are gone.
		if let header = download.cookieHeader, !header.isEmpty {
			return header
		}
		guard let cookies = download.cookies, !cookies.isEmpty else { return nil }
		return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
	}
	
	/// Completes a finished NON-IPA download: the file is already in
	/// place in the ZenithDownloads dir and STAYS there — it is NOT
	/// fed to the package/install flow. Mirrors the completed half
	/// of handlePachageFile's callback (status, history, removal
	/// from the active list, background bookkeeping).
	func _completeNonIPADownload(_ download: Download) {
		DispatchQueue.main.async {
			download.status = .completed
			DownloadManager.shared._recordHistory(for: download, status: .completed)
			DownloadManager.shared._noteCompletedDownload(download)
			DownloadManager.shared._deleteResumeData(for: download.id)
			DownloadManager.shared._deleteMultipartManifest(for: download.id)
			
			if let index = DownloadManager.shared.getDownloadIndex(by: download.id) {
				DownloadManager.shared.downloads.remove(at: index)
				
				#if !targetEnvironment(macCatalyst)
				if #available(iOS 26.0, *) {
					BackgroundTaskManager.shared.updateProgress(for: download.id, progress: 1.0)
				}
				
				self._updateBackgroundAudioState()
				#endif
			}
		}
	}
	
	/// Zenith v2.12 item 7: the single completion hook — called
	/// from the two places a download can finish (`handlePachageFile`
	/// success for IPAs, `_completeNonIPADownload` for everything
	/// else), so every transport (single, multipart, browser-captured)
	/// funnels through it. When the toggle is ON, the finished file
	/// is offered in the system export picker; when OFF (default),
	/// this is a no-op and nothing changes. Runs on main: both
	/// call sites dispatch to the main queue.
	func _noteCompletedDownload(_ download: Download) {
		guard askToSaveToFilesAfterDownload else { return }
		let url = Self._finishedDownloadsDirectory().appendingPathComponent(download.fileName)
		guard FileManager.default.fileExists(atPath: url.path) else { return }
		fileAwaitingSave = url
	}
	
	/// Zenith v2.12 item 7: manual "Save to Files" for one finished
	/// file (history row button). Offers the file in the system
	/// export picker; the original stays in ZenithDownloads.
	func requestSaveToFiles(fileURL: URL) {
		guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
		fileAwaitingSave = fileURL
	}
	
	/// Zenith v2.12 item 7: manual "Save to Files" for a history
	/// entry — resolves the finished file on disk first.
	func requestSaveToFiles(for entry: DownloadHistoryEntry) {
		guard let url = downloadedFileURL(for: entry) else { return }
		requestSaveToFiles(fileURL: url)
	}
	
	/// Zenith v2.12 item 7: clears the pending export picker —
	/// called by the Downloads tab when the picker is picked or
	/// dismissed.
	func dismissSavePrompt() {
		fileAwaitingSave = nil
	}
	
	/// Normalizes a pasted link ONCE, shared by every entry point
	/// (Downloads tab, Library import-from-URL, certificate direct
	/// download): trims whitespace, strips leading slashes, adds
	/// https:// when the scheme is missing, then validates scheme +
	/// host. A link that only needs trimming never fails validation,
	/// and no caller ever loads the raw pasted text.
	static func normalizedURL(from text: String) -> URL? {
		var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		while text.hasPrefix("/") {
			text.removeFirst()
		}
		guard !text.isEmpty else { return nil }
		if !text.contains("://") {
			text = "https://" + text
		}
		guard
			let url = URL(string: text),
			let scheme = url.scheme?.lowercased(),
			scheme == "http" || scheme == "https",
			url.host != nil
		else { return nil }
		return url
	}
	
	private var _session: URLSession!
	
	/// Fixed identifier for the background download session. The
	/// system keeps a background session's tasks alive in its own
	/// daemon across app backgrounding AND app termination, and
	/// re-delivers their events to a session recreated with this
	/// same identifier on the next launch. The old
	/// `URLSessionConfiguration.default` session lived in the app
	/// process: suspending or killing the app killed the task, and
	/// a download killed mid-flight had no resume data at all
	/// (nothing ever captured it — the process just died), so its
	/// resume started from byte 0. That is the restart-from-zero
	/// bug: the manifest remembered the progress, but the bytes
	/// were gone and there was nothing to resume from.
	static let backgroundSessionIdentifier = "com.zenith.app.background-downloads"
	
	/// Completion handler the system hands us when it wakes the app
	/// to deliver background-session events; called from
	/// urlSessionDidFinishEvents(forBackgroundURLSession:).
	private var _backgroundSessionCompletionHandler: (() -> Void)?
	
	/// True from init until the background session's live tasks
	/// have been re-attached (see _reattachBackgroundTasks):
	/// auto-resume must wait until then, or it would start a
	/// second task for a download the daemon is already fetching.
	private var _backgroundReattachPending = true
	
	/// Combine subscriptions owned by the manager: the connectivity
	/// watcher below and the active-download persistence sink.
	private var _cancellables = Set<AnyCancellable>()
	
	/// Last time a progress tick rewrote the active-download JSON.
	/// Progress ticks arrive many times a second; the throttle in
	/// _saveActiveDownloadsThrottled keeps the rewrite to at most
	/// one per 2 seconds. Main thread only (both progress paths
	/// report on main).
	private var _lastProgressSaveDate: Date?
	
	#if !targetEnvironment(macCatalyst)
	private func _updateBackgroundAudioState() {
		if #unavailable(iOS 26.0){
			if !downloads.isEmpty {
				BackgroundAudioManager.shared.start()
			} else  {
				BackgroundAudioManager.shared.stop()
			}
		}
	}
	#endif
	
	override init() {
		super.init()
		let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
		configuration.sessionSendsLaunchEvents = true
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
		_loadHistory()
		
		// Zenith v2.8: pause/resume follows connectivity. The
		// monitor publishes on the main queue, so this runs on main.
		// The first emission is the monitor's initial `false`
		// (unknown) — harmless: there is nothing waiting yet, and
		// the first real path update arrives right after start().
		NetworkMonitor.shared.$isOffline
			.sink { [weak self] isOffline in
				self?._handleConnectivityChanged(isOffline: isOffline)
			}
			.store(in: &_cancellables)
		
		// Zenith v2.10: restore BEFORE subscribing the $downloads
		// sink below. A @Published publisher emits its current
		// value the moment it is subscribed to — subscribing first
		// delivered the still-empty list, _saveActiveDownloads([])
		// overwrote ZenithActiveDownloads.json with [], and the
		// restore that ran afterwards read [] and found nothing.
		// That is why every download vanished on restart: each
		// launch wiped the file before reading it. Restoring first
		// also means the sink's initial emission re-saves the
		// restored list, which is harmless (identical records).
		_restoreActiveDownloads()
		
		// Re-attach the background session's still-running tasks
		// (see _reattachBackgroundTasks): a download the daemon
		// kept fetching across a restart needs no resume at all.
		_reattachBackgroundTasks()
		
		// Persist the active list whenever it changes (a download
		// added, finished or cancelled), so a relaunch never loses
		// or resurrects one. The sink's delivered array is used,
		// not the stored property: @Published sends in willSet, so
		// reading `downloads` inside the sink would see the list
		// BEFORE the change. Flag/status changes save explicitly
		// at the sites that make them.
		$downloads
			.sink { [weak self] downloads in self?._saveActiveDownloads(downloads) }
			.store(in: &_cancellables)
		
		// Zenith v2.10: the app can be killed at any moment while a
		// download runs, and progress ticks are throttled (see
		// _saveActiveDownloadsThrottled) — so take a fresh snapshot
		// when the app backgrounds, and best-effort on terminate,
		// or the JSON on disk holds stale 0% progress when the
		// next launch restores it. This never pauses a download:
		// it only persists where it stands.
		NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
			.sink { [weak self] _ in self?._saveActiveDownloadsOnExit() }
			.store(in: &_cancellables)
		NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
			.sink { [weak self] _ in self?._saveActiveDownloadsOnExit() }
			.store(in: &_cancellables)
	}
	
	// MARK: - Connectivity pause / resume (Zenith v2.8)
	
	/// Connectivity changed: when the internet drops, auto-pause
	/// every download that was actively downloading (never one the
	/// user paused by hand); when it returns, auto-resume only the
	/// downloads flagged waiting-for-internet.
	private func _handleConnectivityChanged(isOffline: Bool) {
		if isOffline {
			for download in downloads where download.status == .downloading {
				_pauseForConnectivity(download)
			}
		} else {
			// The background session's live tasks are not
			// re-attached yet (see _backgroundReattachPending):
			// resuming now would start a second task for a
			// download the daemon is already fetching. The
			// re-attach completion resumes the waiting ones.
			guard !_backgroundReattachPending else { return }
			for download in downloads where download.isWaitingForInternet {
				_resumeAfterConnectivity(download)
			}
		}
	}
	
	/// Auto-pause for a connectivity loss: the same persistence as
	/// a manual pause (resume data / multipart manifest), plus the
	/// waiting flag so the download resumes itself when the
	/// internet returns — and so a relaunch restores it as waiting
	/// instead of losing it.
	func _pauseForConnectivity(_ download: Download) {
		download.isWaitingForInternet = true
		pauseDownload(download)
		_saveActiveDownloads()
	}
	
	/// Auto-resume after connectivity returns. resumeDownload
	/// clears the waiting flag and restarts the transport — and
	/// re-parks the download as waiting if the internet is gone
	/// again by the time it runs.
	private func _resumeAfterConnectivity(_ download: Download) {
		resumeDownload(download)
	}
	
	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		cookies: [HTTPCookie]? = nil
	) -> Download {
		if let existingDownload = downloads.first(where: { $0.url == url }) {
			resumeDownload(existingDownload)
			return existingDownload
		}
		
		let download = Download(id: id, url: url)
		download.cookies = cookies
		if let cookies, !cookies.isEmpty {
			download.cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
		}
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
		} else {
			_updateBackgroundAudioState()
		}
		#endif
		
		// Offline: park the download as waiting — no HEAD probe, no
		// task. It starts itself when connectivity returns, and a
		// relaunch restores it as waiting from disk (the no-internet
		// gate blocks the app while offline, so this mainly guards
		// the download against being lost or failed).
		if NetworkMonitor.shared.isOffline {
			download.isWaitingForInternet = true
			download.status = .paused
			_saveActiveDownloads()
			return download
		}
		
		// The transport is picked asynchronously: a HEAD request checks
		// for Accept-Ranges + a known size, and big range-capable files
		// go through parallel connections, everything else falls back
		// to the plain single-connection download task.
		Task {
			await _beginDownload(download)
		}
		
		return download
	}
	
	/// Starts the install flow for a file the in-app browser already
	/// downloaded: WebKit hands us a finished temp file, so there is
	/// nothing left to fetch — move it into the app's downloads area
	/// and hand it to the package flow exactly like a finished
	/// single-connection download. A non-IPA file skips the install
	/// flow and completes as a plain file download instead.
	func startDownloadFromCapturedFile(
		_ fileURL: URL,
		originalURL: URL,
		id: String = UUID().uuidString
	) {
		let download = Download(id: id, url: originalURL, fileName: fileURL.lastPathComponent)
		download.progress = 1
		if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
		   let size = attributes[.size] as? NSNumber {
			download.totalBytes = size.int64Value
			download.bytesDownloaded = size.int64Value
		}
		downloads.append(download)
		
		do {
			let customTempDir = Self._finishedDownloadsDirectory()
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			let destinationURL = customTempDir.appendingPathComponent(download.fileName)
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: fileURL, to: destinationURL)
			if download.isIPA {
				try handlePachageFile(url: destinationURL, dl: download)
			} else {
				// Not an app package: the file stays in
				// ZenithDownloads and the download completes
				// without the install flow.
				_completeNonIPADownload(download)
			}
		} catch {
			// The browser already finished the file — if moving it
			// into place fails, the download failed honestly instead
			// of hanging in the list forever.
			DispatchQueue.main.async {
				download.status = .failed
				download.errorMessage = error.localizedDescription
				self._recordHistory(for: download, status: .failed)
				if let index = self.getDownloadIndex(by: download.id) {
					self.downloads.remove(at: index)
				}
			}
		}
	}
	
	/// Picks the transport for a new download: multi-connection when the
	/// server supports ranges and the file is big enough, single task
	/// otherwise. Returns after the transport has started.
	private func _beginDownload(_ download: Download) async {
		if download._transportStarted { return }
		if await _startMultipartIfSupported(download) { return }
		// Cancelled while the HEAD probe was in flight: the download
		// is gone, do not start a zombie task for it.
		guard downloads.contains(where: { $0.id == download.id }) else { return }
		// Paused while the HEAD probe was in flight: stay paused.
		if download.status == .paused { return }
		// Resumed while the probe was in flight: the resume already
		// started a transport, do not start a second one.
		if download._transportStarted { return }
		download._transportStarted = true
		_startSingleTask(for: download)
	}
	
	/// HEAD-probes the server; starts a parallel range download when
	/// possible. Returns true when multipart was started. Any probe
	/// failure (server refuses HEAD, no route, timeout) returns false
	/// and the caller falls back to the single-connection task —
	/// a failed probe must never fail the download.
	private func _startMultipartIfSupported(_ download: Download) async -> Bool {
		do {
			var request = URLRequest(url: download.url)
			request.httpMethod = "HEAD"
			request.timeoutInterval = 15
			request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
			if let cookie = _cookieHeaderValue(for: download) {
				request.setValue(cookie, forHTTPHeaderField: "Cookie")
			}
			let (_, response) = try await URLSession.shared.data(for: request)
			guard
				let http = response as? HTTPURLResponse,
				http.expectedContentLength > Self.multipartMinimumSize,
				http.value(forHTTPHeaderField: "Accept-Ranges")?.trimmingCharacters(in: .whitespaces).lowercased() == "bytes",
				download.status != .paused
			else { return false }
			
			let total = http.expectedContentLength
			let multi = ZenithMultipartDownload(
				download: download,
				url: download.url,
				totalBytes: total
			)
			download.multipart = multi
			download.totalBytes = total
			download.isAccelerated = true
			download._transportStarted = true
			await multi.start()
			return true
		} catch {
			return false
		}
	}
	
	/// Starts (or restarts) the plain single-connection download task.
	/// A browser user agent is attached: some hosts refuse the
	/// default URLSession agent and the download would fail at once.
	/// Redirects are followed by URLSession's default handling — no
	/// delegate method overrides it anywhere in this file.
	func _startSingleTask(for download: Download) {
		download.multipart = nil
		download.isAccelerated = false
		var request = URLRequest(url: download.url)
		request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
		if let cookie = _cookieHeaderValue(for: download) {
			request.setValue(cookie, forHTTPHeaderField: "Cookie")
		}
		let task = _session.downloadTask(with: request)
		// The download id, so a task the system kept alive across
		// a relaunch can be matched back to its Download (see
		// _download(for:) / _reattachBackgroundTasks).
		task.taskDescription = download.id
		download.task = task
		task.resume()
	}
	
	/// Finds the Download for a session task: by the live `task`
	/// reference first, then by the taskDescription (the download
	/// id). A task the system kept alive across a relaunch has a
	/// Download whose `task` is nil until _reattachBackgroundTasks
	/// runs, and a completion delivered before that must not be
	/// dropped — the taskDescription is what matches it.
	private func _download(for task: URLSessionTask) -> Download? {
		if let downloadTask = task as? URLSessionDownloadTask,
		   let found = getDownloadTask(by: downloadTask) {
			return found
		}
		guard let id = task.taskDescription, !id.isEmpty else { return nil }
		return getDownload(by: id)
	}
	
	/// Called by the AppDelegate when the system wakes the app to
	/// deliver background-session events. Touching
	/// DownloadManager.shared creates the session (same
	/// identifier), so the pending events are delivered to it;
	/// the handler is called once they are all delivered (see
	/// urlSessionDidFinishEvents(forBackgroundURLSession:)).
	func _handleBackgroundSessionEvents(completionHandler: @escaping () -> Void) {
		_backgroundSessionCompletionHandler = completionHandler
	}
	
	/// Re-attaches the background session's still-running tasks to
	/// their restored Download objects after a relaunch. A task
	/// that is still alive in the daemon needs no resume at all —
	/// it just keeps fetching, and its progress callbacks resume
	/// the moment the app runs again. When the re-attach is done
	/// the waiting downloads that have NO live task are resumed
	/// (from persisted resume data / multipart manifest), which
	/// also covers the launch-time auto-resume: the connectivity
	/// watcher's initial emission fires before the restore, so it
	/// cannot resume them itself.
	private func _reattachBackgroundTasks() {
		_session.getAllTasks { [weak self] tasks in
			DispatchQueue.main.async {
				guard let self else { return }
				for task in tasks {
					guard
						let downloadTask = task as? URLSessionDownloadTask,
						let id = downloadTask.taskDescription,
						!id.isEmpty,
						let download = self.getDownload(by: id)
					else { continue }
					// A fresh task was already started for this
					// download (a resume beat the re-attach): the
					// old daemon task is a duplicate — cancel it
					// instead of running two tasks for one file.
					if download.task != nil {
						downloadTask.cancel()
						continue
					}
					download.task = downloadTask
					download._transportStarted = true
					download.status = .downloading
					download.isWaitingForInternet = false
					download.errorMessage = nil
					
					#if !targetEnvironment(macCatalyst)
					if #available(iOS 26.0, *) {
						BackgroundTaskManager.shared.startTask(for: download.id, filename: download.fileName)
					}
					#endif
				}
				self._backgroundReattachPending = false
				self._saveActiveDownloads()
				// Now that the live tasks are known, resume the
				// waiting ones that have none.
				self._handleConnectivityChanged(isOffline: NetworkMonitor.shared.isOffline)
			}
		}
	}
	
	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif
		
		return download
	}
	
	func resumeDownload(_ download: Download) {
		// Offline: park as waiting — no transport until the
		// internet returns. The connectivity watcher resumes it
		// then; a manual resume while offline behaves the same
		// (the user asked for the download to continue, so it
		// continues on its own once the internet is back).
		if NetworkMonitor.shared.isOffline {
			download.isWaitingForInternet = true
			download.status = .paused
			download.errorMessage = nil
			_saveActiveDownloads()
			return
		}
		
		// The download already has a live task (re-attached from
		// the background session after a relaunch, or started by
		// an earlier resume): it is already fetching — starting
		// a second task would download the same file twice and
		// corrupt the progress. A suspended task is resumed.
		if let task = download.task {
			if task.state == .running {
				download.isWaitingForInternet = false
				download.status = .downloading
				download.errorMessage = nil
				_saveActiveDownloads()
				return
			}
			if task.state == .suspended {
				task.resume()
				download.isWaitingForInternet = false
				download.status = .downloading
				download.errorMessage = nil
				_saveActiveDownloads()
				return
			}
		}
		
		download.isWaitingForInternet = false
		download.status = .downloading
		download.errorMessage = nil
		_saveActiveDownloads()
		// A transport is started below; tell the still-running HEAD
		// probe (if any) not to start a second one.
		download._transportStarted = true
		
		// A resume must keep the download alive in the background
		// too: startTask is not only for fresh downloads. The old
		// code only submitted the background task in startDownload,
		// so a download resumed after a pause (or after an
		// expiry-pause) had no background time at all on iOS 26+
		// — backgrounding again killed it at once. (On iOS 26+
		// the background-audio keep-alive is a no-op, so the
		// BGContinuedProcessingTask is the only keep-alive.)
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: download.id, filename: download.fileName)
		}
		#endif
		
		// Multi-connection download that was paused: restart its parts
		// from the persisted per-part byte counts.
		if let multi = download.multipart {
			multi.resume()
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
			return
		}
		
		if let manifest = _loadMultipartManifest(for: download.id) {
			let multi = ZenithMultipartDownload(
				download: download,
				url: download.url,
				totalBytes: manifest.totalBytes,
				partCount: manifest.partCount,
				resumingPartDownloaded: manifest.partDownloaded
			)
			download.multipart = multi
			download.totalBytes = manifest.totalBytes
			download.isAccelerated = true
			Task { await multi.start() }
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
			return
		}
		
		// Single-connection download: resume from the persisted resume
		// data so an interrupted download continues, not restarts.
		if let resumeData = _loadResumeData(for: download.id) ?? download.resumeData {
			let task = _session.downloadTask(withResumeData: resumeData)
			task.taskDescription = download.id
			download.task = task
			task.resume()
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		} else if let url = download.task?.originalRequest?.url {
			var request = URLRequest(url: url)
			request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
			if let cookie = _cookieHeaderValue(for: download) {
				request.setValue(cookie, forHTTPHeaderField: "Cookie")
			}
			let task = _session.downloadTask(with: request)
			task.taskDescription = download.id
			download.task = task
			task.resume()
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		} else {
			_startSingleTask(for: download)
		}
	}
	
	/// Pauses a download, persisting resume data (single-connection) or
	/// the per-part manifest (multi-connection) so it continues later.
	/// A manual pause never sets the waiting flag, so it is never
	/// auto-resumed: only the connectivity paths set the flag, and
	/// resumeDownload clears it.
	/// Zenith v2.11: the visible state flips FIRST, synchronously.
	/// The old code only set `.paused` inside async callbacks — the
	/// resume-data callback for a single-connection download, a
	/// detached MainActor task for a multi-connection one — so a
	/// slow or never-firing callback left the row stuck showing
	/// Pause (and the download still running) after the user tapped
	/// it: the tap looked dead. Cancelling the transport is what
	/// stops the bytes; the status must not wait on the callback.
	func pauseDownload(_ download: Download) {
		download.status = .paused
		if let multi = download.multipart {
			multi.pause()
			_saveActiveDownloads()
			return
		}

		guard let task = download.task else {
			_saveActiveDownloads()
			return
		}

		task.cancel(byProducingResumeData: { [weak self] data in
			if let data {
				self?._saveResumeData(data, for: download.id)
				download.resumeData = data
			}
			Task { @MainActor in
				download.status = .paused
				self?._saveActiveDownloads()
			}
		})
		// Zenith v2.11: persist the paused record NOW, not only in
		// the resume-data callback above. The callback runs
		// asynchronously and may never land if the app is killed
		// (e.g. right after a background-task expiry) — without
		// this write the JSON on disk would still hold the
		// pre-pause record. The status is already .paused (set
		// above), so this snapshot restores as paused with the
		// real progress; the callback's later save only adds the
		// resume data to disk.
		_saveActiveDownloads()
	}
	
	/// Retry is a resume: a failed or paused download continues from
	/// where it stopped instead of starting from zero.
	func retryDownload(_ download: Download) {
		resumeDownload(download)
	}
	
	func cancelDownload(_ download: Download) {
		download.multipart?.cancel()
		download.multipart = nil
		download.task?.cancel()
		_deleteResumeData(for: download.id)
		_deleteMultipartManifest(for: download.id)
		
		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()

			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			}
			#endif
		}
	}
	
	func isManualDownload(_ string: String) -> Bool {
		return string.contains("ZenithManualDownload")
	}
	
	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}
	
	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}
	
	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}
	
	// MARK: - Download history (persisted)
	
	private var _historyURL: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("ZenithDownloadHistory.json")
	}
	
	private func _loadHistory() {
		guard let data = try? Data(contentsOf: _historyURL) else { return }
		history = (try? JSONDecoder().decode([DownloadHistoryEntry].self, from: data)) ?? []
		// Zenith v2.13 Fix 4: older builds recorded Library
		// imports here with a file:// URL — a local file that was
		// never downloaded and can never be re-downloaded. Drop
		// those rows (and persist the cleanup) so they stop
		// showing as downloads.
		let loadedCount = history.count
		history.removeAll { entry in
			guard let scheme = URL(string: entry.urlString)?.scheme?.lowercased() else { return true }
			return scheme != "http" && scheme != "https"
		}
		if history.count != loadedCount {
			_saveHistory()
		}
	}
	
	private func _saveHistory() {
		try? JSONEncoder().encode(history).write(to: _historyURL)
	}
	
	/// Records a finished download. Keeps the newest 50 entries.
	/// Completed entries remember the file's on-disk name, so the
	/// Downloads tab can open the finished file later.
	/// Zenith v2.13 Fix 4: a Library file-picker import is a local
	/// file, never a download (`onlyArchiving`) — it must never
	/// land in Download History. The guard lives here, at the
	/// single choke point, so every completion path is covered
	/// and no future caller can record an import by accident.
	func _recordHistory(for download: Download, status: DownloadHistoryStatus) {
		guard !download.onlyArchiving else { return }
		let entry = DownloadHistoryEntry(
			id: download.id,
			fileName: download.fileName,
			urlString: download.url.absoluteString,
			date: Date(),
			status: status,
			totalBytes: download.totalBytes,
			localFileName: status == .completed ? download.fileName : nil
		)
		history.removeAll(where: { $0.id == entry.id })
		// Zenith v2.13 Fix 5: a retry that finally succeeds
		// supersedes the earlier failed attempt of the same link.
		// Without this the history showed both the failed row and
		// the completed row for one file (double-recording).
		if status == .completed {
			history.removeAll(where: { $0.urlString == entry.urlString && $0.status == .failed })
		}
		history.insert(entry, at: 0)
		if history.count > 50 {
			history = Array(history.prefix(50))
		}
		_saveHistory()
	}
	
	func clearHistory() {
		history.removeAll()
		_saveHistory()
	}
	
	/// Retry a history entry: starts a fresh download of the same URL.
	/// Zenith v2.13 Fix 4: only http(s) links can be re-downloaded —
	/// a legacy file:// row (a Library import recorded by an older
	/// build) must never spawn a broken download attempt.
	func retryHistoryEntry(_ entry: DownloadHistoryEntry) {
		guard
			let url = URL(string: entry.urlString),
			let scheme = url.scheme?.lowercased(),
			scheme == "http" || scheme == "https"
		else { return }
		_ = startDownload(from: url, id: "ZenithManualDownload_\(UUID().uuidString)")
	}
	
	/// Home of finished downloads. Caches, not temporaryDirectory:
	/// tmp may be purged while the app is not running, which would
	/// orphan a completed history entry from its file after a
	/// restart. Caches survives restarts (purged only under storage
	/// pressure). Every writer uses this helper — never a literal.
	static func _finishedDownloadsDirectory() -> URL {
		FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("ZenithDownloads", isDirectory: true)
	}
	
	/// URL of the finished file on disk for a completed history
	/// entry, or nil when the entry has no recorded file or the file
	/// is no longer in the ZenithDownloads dir.
	func downloadedFileURL(for entry: DownloadHistoryEntry) -> URL? {
		guard let name = entry.localFileName, !name.isEmpty else { return nil }
		let url = Self._finishedDownloadsDirectory().appendingPathComponent(name)
		if FileManager.default.fileExists(atPath: url.path) { return url }
		// Files finished before the v2.10 move still live in tmp.
		let legacyURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("ZenithDownloads", isDirectory: true)
			.appendingPathComponent(name)
		return FileManager.default.fileExists(atPath: legacyURL.path) ? legacyURL : nil
	}
	
	// MARK: - Resume data persistence (single-connection)
	
	private var _resumeDataDirectory: URL {
		let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("ZenithResume", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}
	
	private func _resumeDataURL(for id: String) -> URL {
		_resumeDataDirectory.appendingPathComponent("\(id).resume")
	}
	
	func _saveResumeData(_ data: Data, for id: String) {
		// Atomic: a kill mid-write must never leave a torn resume
		// file behind — an unreadable resume file forces the
		// resume from zero.
		try? data.write(to: _resumeDataURL(for: id), options: .atomic)
	}
	
	func _loadResumeData(for id: String) -> Data? {
		try? Data(contentsOf: _resumeDataURL(for: id))
	}
	
	func _deleteResumeData(for id: String) {
		try? FileManager.default.removeItem(at: _resumeDataURL(for: id))
	}
	
	// MARK: - Multipart manifest persistence
	
	func _loadMultipartManifest(for id: String) -> ZenithMultipartManifest? {
		let url = ZenithMultipartDownload.manifestURL(for: id)
		guard let data = try? Data(contentsOf: url) else { return nil }
		return try? JSONDecoder().decode(ZenithMultipartManifest.self, from: data)
	}
	
	func _deleteMultipartManifest(for id: String) {
		try? FileManager.default.removeItem(at: ZenithMultipartDownload.manifestURL(for: id))
		try? FileManager.default.removeItem(at: ZenithMultipartDownload.tempFileURL(for: id))
	}
	
	// MARK: - Active-download persistence (relaunch restore)
	
	private var _activeDownloadsURL: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("ZenithActiveDownloads.json")
	}
	
	/// Persists the active (unfinished, non-archive) downloads so a
	/// relaunch restores them instead of losing them. The resume
	/// data / multipart manifest already live on disk — but the
	/// Download object itself is in-memory only, so without this
	/// record the download would be gone when the app restarts and
	/// its persisted resume data orphaned. Archive downloads
	/// (Library file-picker imports) are local files, not network
	/// downloads, and are never restored.
	
	/// Saves the active list from a progress tick, throttled to at
	/// most one write per 2 seconds. Without this the JSON on disk
	/// keeps the 0% snapshot written when the download was added
	/// (progress/byte counts only change on the Download object,
	/// never on the array, so the $downloads sink never fires for
	/// them) and a relaunch restores 0% with an unknown size.
	/// Returns true when it actually wrote, so the multipart
	/// reporter can persist its per-part manifest on the same beat.
	/// Main thread only: didWriteData and the multipart progress
	/// reporter both run on main.
	@discardableResult
	func _saveActiveDownloadsThrottled() -> Bool {
		let now = Date()
		if let last = _lastProgressSaveDate, now.timeIntervalSince(last) < 2 { return false }
		_lastProgressSaveDate = now
		_saveActiveDownloads()
		return true
	}
	
	/// Fresh snapshot when the app leaves the foreground (and
	/// best-effort on terminate): the active-list JSON plus every
	/// multipart manifest, so a kill after backgrounding still
	/// resumes from the real byte counts instead of the last
	/// throttled tick. Called from the background/terminate
	/// observers in init; it never pauses or cancels anything.
	private func _saveActiveDownloadsOnExit() {
		_saveActiveDownloads()
		for download in downloads {
			download.multipart?.persistManifest()
		}
	}
	
	func _saveActiveDownloads(_ list: [Download]? = nil) {
		let records = (list ?? downloads)
			.filter { !$0.onlyArchiving }
			.map { download in
				PersistedActiveDownload(
					id: download.id,
					urlString: download.url.absoluteString,
					fileName: download.fileName,
					isWaitingForInternet: download.isWaitingForInternet,
					status: download.status._persistedName,
					errorMessage: download.errorMessage,
					progress: download.progress,
					bytesDownloaded: download.bytesDownloaded,
					totalBytes: download.totalBytes,
					cookieHeader: download.cookieHeader
				)
			}
		if let data = try? JSONEncoder().encode(records) {
			try? data.write(to: _activeDownloadsURL, options: .atomic)
		}
	}
	
	/// Restores the downloads saved by _saveActiveDownloads: they
	/// come back paused (waiting-for-internet when flagged), and
	/// the connectivity watcher resumes the waiting ones as soon
	/// as the internet is back. resumeDownload picks up the
	/// persisted resume data / multipart manifest from disk, so a
	/// resumed download continues from its byte counts instead of
	/// restarting. A download killed mid-flight with no persisted
	/// resume data restarts from zero — it is still not lost.
	private func _restoreActiveDownloads() {
		guard let data = try? Data(contentsOf: _activeDownloadsURL) else { return }
		// Zenith v2.11: the old all-or-nothing decode dropped EVERY
		// download when a single record failed to decode (a torn
		// write, a future schema change) — and the $downloads sink
		// subscribed right after then persisted [] over the file,
		// making the loss permanent. Decode element by element on
		// failure, so one bad record can never wipe the whole list.
		let records: [PersistedActiveDownload]
		if let decoded = try? JSONDecoder().decode([PersistedActiveDownload].self, from: data) {
			records = decoded
		} else if
			let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
		{
			records = raw.compactMap { element in
				guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
				return try? JSONDecoder().decode(PersistedActiveDownload.self, from: elementData)
			}
		} else {
			return
		}
		for record in records {
			guard let url = URL(string: record.urlString) else { continue }
			guard !downloads.contains(where: { $0.id == record.id }) else { continue }
			let download = Download(id: record.id, url: url, fileName: record.fileName)
			download.cookieHeader = record.cookieHeader
			download.progress = record.progress
			download.bytesDownloaded = record.bytesDownloaded
			download.totalBytes = record.totalBytes
			download.isWaitingForInternet = record.isWaitingForInternet
			if record.status == "failed" {
				download.status = .failed
				download.errorMessage = record.errorMessage
			} else {
				// A download caught mid-flight (or mid-HEAD-probe)
				// by a restart has no running transport: paused.
				// A record saved mid-flight ("downloading") was
				// NOT paused by the user — it was caught by a
				// restart, so park it as waiting: the re-attach
				// completion resumes it on launch (from its
				// persisted resume data / multipart manifest), and
				// the connectivity watcher resumes it whenever
				// the internet returns. A record the user paused
				// by hand ("paused") stays paused.
				download.status = .paused
				if record.status == "downloading" {
					download.isWaitingForInternet = true
				}
			}
			downloads.append(download)
		}
	}
	
	// MARK: - Speed probe (before big downloads)
	
	/// HEAD-probes the file size. Returns nil when the server hides it.
	func probeContentLength(for url: URL) async -> Int64? {
		var request = URLRequest(url: url)
		request.httpMethod = "HEAD"
		request.timeoutInterval = 15
		request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
		guard
			let (_, response) = try? await URLSession.shared.data(for: request),
			let http = response as? HTTPURLResponse,
			http.expectedContentLength > 0
		else { return nil }
		return http.expectedContentLength
	}
	
	/// Measures real throughput by fetching the first 256 KiB of the
	/// file with a Range request. Returns bytes/sec, or nil when the
	/// probe fails (inconclusive — the download proceeds unwarned).
	/// Streams the bytes and stops at 256 KiB: a server that ignores
	/// Range and answers 200 must never dump the whole file into
	/// memory here (on a big IPA that would kill the app outright).
	func probeConnectionSpeed(for url: URL) async -> Double? {
		var request = URLRequest(url: url)
		request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
		request.timeoutInterval = 12
		request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
		let start = Date()
		do {
			let (bytes, response) = try await URLSession.shared.bytes(for: request)
			guard (response as? HTTPURLResponse)?.statusCode == 206 else { return nil }
			var received = 0
			for try await _ in bytes {
				received += 1
				if received >= 262144 { break }
			}
			let elapsed = Date().timeIntervalSince(start)
			guard received > 0, elapsed > 0 else { return nil }
			return Double(received) / elapsed
		} catch {
			return nil
		}
	}
}

extension DownloadManager: URLSessionDownloadDelegate {
	
	func handlePachageFile(url: URL, dl: Download) throws {
		Zenith.handlePackageFile(url, download: dl) { err in
			if err != nil {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)
			}
			
			DispatchQueue.main.async {
				if err == nil {
					dl.status = .completed
					DownloadManager.shared._recordHistory(for: dl, status: .completed)
					// Zenith v2.13 Fix 4: an import never triggers
					// the save prompt — its file is not in
					// ZenithDownloads, so the lookup could offer a
					// same-named older download instead of it.
					if !dl.onlyArchiving {
						DownloadManager.shared._noteCompletedDownload(dl)
					}
				} else {
					dl.status = .failed
					dl.errorMessage = err?.localizedDescription
					DownloadManager.shared._recordHistory(for: dl, status: .failed)
				}
				DownloadManager.shared._deleteResumeData(for: dl.id)
				DownloadManager.shared._deleteMultipartManifest(for: dl.id)
				
				if let index = DownloadManager.shared.getDownloadIndex(by: dl.id) {
					DownloadManager.shared.downloads.remove(at: index)
					
					#if !targetEnvironment(macCatalyst)
					if #available(iOS 26.0, *) {
						BackgroundTaskManager.shared.updateProgress(for: dl.id, progress: 1.0)
					}
					
					self._updateBackgroundAudioState()
					#endif
				}
			}
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = _download(for: downloadTask) else { return }
		
		// A 4xx/5xx answer still "finishes" as a download — it is an
		// error page, not the file. The same goes for a 200 that
		// serves an HTML page instead of a file. Fail honestly here
		// instead of feeding an HTML page to the installer. Only
		// text/html counts as an error page: real text files
		// (.txt/.csv/.json) must download.
		if let http = downloadTask.response as? HTTPURLResponse {
			let isErrorPage = !(200...299).contains(http.statusCode)
				|| http.mimeType?.lowercased() == "text/html"
			if isErrorPage {
				DispatchQueue.main.async {
					download.status = .failed
					download.errorMessage = "HTTP \(http.statusCode)"
					DownloadManager.shared._recordHistory(for: download, status: .failed)
					// Zenith v2.13 Fix 5: keep the failed download
					// in the active list, like every other failure
					// path (transport error, multipart error) — the
					// old code removed it here, so its Retry button
					// vanished while other failures kept theirs.
					DownloadManager.shared._saveActiveDownloads()
				}
				return
			}
		}
		
		let customTempDir = Self._finishedDownloadsDirectory()
		
		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			
			// Use the server-suggested filename if available, otherwise fallback
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			let destinationURL = customTempDir.appendingPathComponent(suggestedFileName)
			
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			
			// The server's name is the real file name (a direct link
			// can end in an extension-less endpoint path): adopt it
			// so the install decision and the history entry name the
			// file that is actually on disk.
			download.fileName = suggestedFileName
			
			if download.isIPA {
				try handlePachageFile(url: destinationURL, dl: download)
			} else {
				// Not an app package: the file stays in
				// ZenithDownloads and the download completes
				// without the install flow.
				_completeNonIPADownload(download)
			}
		} catch {
			print("Error handling downloaded file: \(error.localizedDescription)")
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let download = _download(for: downloadTask) else { return }
		
		DispatchQueue.main.async {
			download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0
			download.bytesDownloaded = totalBytesWritten
			download.totalBytes = totalBytesExpectedToWrite
			
			// Real throughput + ETA from the live byte counts,
			// smoothed (see Download._updateSpeedAndETA) so the
			// numbers never jump wildly on one short sample.
			download._updateSpeedAndETA(
				totalDownloaded: totalBytesWritten,
				totalBytes: totalBytesExpectedToWrite,
				now: Date()
			)
			
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
			}
			#endif
			
			// Zenith v2.10: persist progress as it moves
			// (throttled to one write per 2s) — otherwise the
			// JSON on disk keeps the 0% snapshot from when the
			// download was added, and a relaunch restores 0%.
			// A single-connection download killed mid-flight has
			// no resume data on disk, so its resume restarts the
			// transport automatically (never asks for the link
			// again); the saved byte counts still show the real
			// progress it had reached.
			self._saveActiveDownloadsThrottled()
		}
	}
	
	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard
			let error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = _download(for: downloadTask)
		else {
			return
		}
		
		// A pause cancels the task on purpose — that is not a failure.
		if (error as NSError).code == NSURLErrorCancelled { return }
		
		// Keep the resume data the system hands us, on disk, so a retry
		// continues from where the download stopped, not from zero.
		if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
			download.resumeData = resumeData
			_saveResumeData(resumeData, for: download.id)
		}
		
		// Zenith v2.8: the internet dropped mid-download — pause and
		// wait for it instead of failing. The resume data above is
		// already on disk, so the auto-resume continues from the
		// same byte counts. No failed history entry: this is not a
		// failure, and the user must never see one for it.
		if _isConnectivityError(error) || NetworkMonitor.shared.isOffline {
			DispatchQueue.main.async {
				download.isWaitingForInternet = true
				download.status = .paused
				download.errorMessage = nil
				self._saveActiveDownloads()
			}
			return
		}
		
		// The resume data the system handed us (above) is the only
		// trustworthy one. If this task received zero bytes and
		// produced no resume data, the resume data it STARTED from
		// is poison (e.g. written by an older build's session, or
		// a torn file): keeping it would make every retry fail the
		// same way. Drop it so the next retry starts clean instead
		// of looping on the same bad data. A task that DID receive
		// bytes keeps the older data — stale, but resumable.
		if downloadTask.countOfBytesReceived == 0,
		   (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data == nil {
			download.resumeData = nil
			_deleteResumeData(for: download.id)
		}
		
		DispatchQueue.main.async {
			download.status = .failed
			download.errorMessage = error.localizedDescription
			self._recordHistory(for: download, status: .failed)
			self._saveActiveDownloads()
			
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			}
			
			self._updateBackgroundAudioState()
			#endif
		}
	}
	
	/// All background-session events the system woke the app for
	/// have been delivered: tell it we are done, so it can
	/// suspend the app again (and snapshot the UI).
	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		DispatchQueue.main.async {
			self._backgroundSessionCompletionHandler?()
			self._backgroundSessionCompletionHandler = nil
		}
	}
}

// MARK: - Download history

enum DownloadHistoryStatus: String, Codable {
	case completed
	case failed
}

/// One finished download, kept on disk so the Downloads tab can show
/// history and offer a retry for failures.
struct DownloadHistoryEntry: Codable, Identifiable {
	var id: String
	var fileName: String
	var urlString: String
	var date: Date
	var status: DownloadHistoryStatus
	var totalBytes: Int64
	/// On-disk name of the finished file in the ZenithDownloads dir
	/// (completed entries only). Optional with a default, so history
	/// JSON saved by older versions — without this key — still
	/// decodes (synthesized Decodable uses decodeIfPresent for
	/// Optional properties).
	var localFileName: String? = nil
}

/// One active (not yet finished) download, persisted so a relaunch
/// restores it instead of losing it. `status` is "failed" for a
/// failed download (restored as failed, with its error message) and
/// anything else restores as paused — a download caught
/// mid-flight has no running transport after a restart.
/// `cookieHeader` is the plain "Cookie" header string: it survives
/// the restore where HTTPCookie objects cannot be persisted.
struct PersistedActiveDownload: Codable {
	var id: String
	var urlString: String
	var fileName: String
	var isWaitingForInternet: Bool
	var status: String
	var errorMessage: String?
	var progress: Double
	var bytesDownloaded: Int64
	var totalBytes: Int64
	var cookieHeader: String?
}

extension PersistedActiveDownload {
	/// Tolerant decode (Zenith v2.15): every field falls back to
	/// a safe default instead of failing the whole record. The
	/// old synthesized decode dropped a download from the restore
	/// whenever ONE field was bad (a torn write, a value saved by
	/// an older build in another shape) — the row vanished and the
	/// download looked lost / "restarted". Only a row with no
	/// usable id or URL is unrecoverable, and the restore loop
	/// already skips those.
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = (try? container.decode(String.self, forKey: .id)) ?? ""
		urlString = (try? container.decode(String.self, forKey: .urlString)) ?? ""
		fileName = (try? container.decode(String.self, forKey: .fileName)) ?? "download"
		isWaitingForInternet = (try? container.decode(Bool.self, forKey: .isWaitingForInternet)) ?? false
		// A record with no status was most likely saved mid-flight.
		status = (try? container.decode(String.self, forKey: .status)) ?? "downloading"
		errorMessage = try? container.decode(String.self, forKey: .errorMessage)
		progress = (try? container.decode(Double.self, forKey: .progress)) ?? 0
		bytesDownloaded = (try? container.decode(Int64.self, forKey: .bytesDownloaded))
			?? (try? container.decode(Double.self, forKey: .bytesDownloaded)).map(Int64.init)
			?? 0
		totalBytes = (try? container.decode(Int64.self, forKey: .totalBytes))
			?? (try? container.decode(Double.self, forKey: .totalBytes)).map(Int64.init)
			?? 0
		cookieHeader = try? container.decode(String.self, forKey: .cookieHeader)
	}
}

// MARK: - Multi-connection download

/// True when an error is a connectivity failure (no route to the
/// host, or the connection dropped mid-transfer): the download
/// must pause and wait for the internet, never fail. Used by the
/// single-task delegate, the multi-connection parts, and the
/// finish path, so every transport agrees on what counts.
fileprivate func _isConnectivityError(_ error: Error) -> Bool {
	let nsError = error as NSError
	guard nsError.domain == NSURLErrorDomain else { return false }
	return nsError.code == NSURLErrorNotConnectedToInternet
		|| nsError.code == NSURLErrorNetworkConnectionLost
}

/// Persisted per-part progress of a multi-connection download, so a
/// paused or interrupted download resumes from its parts' byte counts.
struct ZenithMultipartManifest: Codable {
	var urlString: String
	var totalBytes: Int64
	var partCount: Int
	var partDownloaded: [Int64]
	var tempFileName: String
}

/// Downloads one file over 2–4 parallel HTTP Range connections and
/// reassembles the parts into a single file. Correctness first: every
/// part tracks its own downloaded byte count, progress is persisted to
/// a manifest on pause/failure, and any server that does not really
/// support ranges (no 206) falls back to the single-connection task.
/// All mutable state is guarded by one lock; progress is reported to
/// the shared Download object on the main actor, throttled to 4 Hz.
final class ZenithMultipartDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
	private let download: Download
	private let url: URL
	private let totalBytes: Int64
	private let partCount: Int
	private let tempURL: URL
	private let manifestURL: URL
	/// An implicitly-unwrapped optional, not a plain var: the
	/// session takes self as its delegate, so it can only be
	/// created after super.init() — and Swift requires every
	/// stored property to be initialized BEFORE super.init(), so
	/// a plain var still fails the build. The IUO starts as nil
	/// and is assigned exactly once in init, before any use
	/// (same pattern as _session in DownloadManager above).
	private var session: URLSession!
	
	/// Live per-part data tasks, by part index — so a pause /
	/// cancel / failover can stop the network task itself, not
	/// just the Swift Task awaiting it.
	private var _partDataTasks: [Int: URLSessionDataTask] = [:]
	/// Continuations the part Tasks are suspended in, by the
	/// URLSession task identifier — resumed exactly once from
	/// urlSession(_:task:didCompleteWithError:).
	private var _partContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
	/// Part index + start() generation per live data task, by the
	/// URLSession task identifier — the delegate validates the
	/// generation before acting, so a stale task can never write
	/// into a part a resume relaunched.
	private var _partTaskInfo: [Int: (partIndex: Int, generation: Int)] = [:]
	
	private let lock = NSLock()
	private var partDownloaded: [Int64]
	private var partTasks: [Task<Void, Never>] = []
	private var fileHandle: FileHandle?
	private var startTime = Date()
	private var lastReportDate = Date()
	private var _failedError: Error?
	private var _didFailOver = false
	private var _cancelled = false
	private var _isDead = false

	/// Generation of the currently-running start(): pause, resume
	/// and cancel bump it, so a stale start() that is still winding
	/// down — its part tasks were cancelled but its _finish had not
	/// run yet — can never act on the download again. Zenith v2.11:
	/// a quick pause-then-resume used to let the OLD _finish run
	/// after resume() had cleared _cancelled, see an unfinished
	/// file, and fail over to a fresh single-connection download —
	/// cancelling the resumed parts and throwing the multipart
	/// progress away, so the resume looked dead. Guarded by `lock`
	/// with the rest of the mutable state.
	private var _generation = 0

	/// Current generation, under the lock.
	private func _currentGeneration() -> Int {
		lock.lock()
		defer { lock.unlock() }
		return _generation
	}
	
	init(
		download: Download,
		url: URL,
		totalBytes: Int64,
		partCount: Int = 4,
		resumingPartDownloaded: [Int64]? = nil
	) {
		self.download = download
		self.url = url
		self.totalBytes = totalBytes
		self.partCount = min(max(partCount, 2), 4)
		self.tempURL = Self.tempFileURL(for: download.id)
		self.manifestURL = Self.manifestURL(for: download.id)
		if
			let resuming = resumingPartDownloaded,
			resuming.count == self.partCount
		{
			self.partDownloaded = resuming
		} else {
			self.partDownloaded = Array(repeating: 0, count: self.partCount)
		}
		// The session takes self as its delegate (chunked data
		// delivery — see _runPart and the URLSessionDataDelegate
		// methods below), so it is created after super.init(),
		// once every other property is set.
		super.init()
		self.session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
	}
	
	deinit {
		session.invalidateAndCancel()
	}
	
	static func _multipartDirectory() -> URL {
		// Zenith v2.10: the part temp file + manifest must survive
		// an app restart — temporaryDirectory may be purged while
		// the app is not running, which would drop the part file
		// and the offsets and force a resume from zero. Caches
		// survives restarts (purged only under storage pressure)
		// and is the same home the single-connection resume data
		// already uses. Downloads started before this move keep
		// their tmp files, but a resume after the move finds no
		// manifest/temp file here and restarts that one download
		// from zero automatically — the entry itself is not lost.
		FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("ZenithMultipart", isDirectory: true)
	}
	
	static func tempFileURL(for id: String) -> URL {
		_multipartDirectory().appendingPathComponent("multipart-\(id).tmp")
	}
	
	static func manifestURL(for id: String) -> URL {
		_multipartDirectory().appendingPathComponent("multipart-\(id).json")
	}
	
	private var _partSize: Int64 {
		(totalBytes + Int64(partCount) - 1) / Int64(partCount)
	}
	
	/// Starts (or restarts) all parts and waits until every part has
	/// finished, failed, or been cancelled. Safe to call again for a
	/// resume: parts restart from their stored byte counts.
	func start() async {
		try? FileManager.default.createDirectoryIfNeeded(at: Self._multipartDirectory())
		
		// If the OS purged the temp file, the stored offsets are
		// meaningless — restart from zero instead of shipping a
		// file full of holes.
		if !FileManager.default.fileExists(atPath: tempURL.path) {
			FileManager.default.createFile(atPath: tempURL.path, contents: nil)
			lock.lock()
			partDownloaded = Array(repeating: 0, count: partCount)
			lock.unlock()
		}
		
		lock.lock()
		if fileHandle == nil {
			fileHandle = try? FileHandle(forWritingTo: tempURL)
		}
		partTasks = []
		let cancelled = _cancelled
		lock.unlock()
		
		// Paused again before the parts launched (resume then instant
		// pause): do not launch, just persist the manifest.
		if cancelled {
			_persistManifest()
			return
		}

		// Generation this start() owns: a pause/resume/cancel since
		// launch bumps it, and the stale _finish / part below must
		// then do nothing (see _generation).
		let generation = _currentGeneration()

		startTime = Date()
		lastReportDate = Date()

		for index in 0..<partCount {
			_launchPart(index, generation: generation)
		}

		lock.lock()
		let tasks = partTasks
		lock.unlock()
		for task in tasks {
			await task.value
		}
		await _finish(generation: generation)
	}
	
	/// Pauses: cancels the part tasks; _finish persists the manifest
	/// so resume continues from the per-part byte counts.
	/// Zenith v2.11: persists the manifest here, synchronously —
	/// the stale _finish of this start() is now a no-op once a
	/// resume bumps the generation, so it can no longer be relied
	/// on to persist the offsets.
	func pause() {
		lock.lock()
		_cancelled = true
		_generation += 1
		let tasks = partTasks
		lock.unlock()
		for task in tasks {
			task.cancel()
		}
		_cancelDataTasks()
		_persistManifest()
		Task { @MainActor in
			download.status = .paused
		}
	}
	
	/// Persists the per-part byte counts now. Used by the
	/// throttled progress save and by the background/terminate
	/// save in DownloadManager: a kill mid-download must find
	/// the offsets on disk, or resume restarts from zero.
	func persistManifest() {
		_persistManifest()
	}
	
	/// Zenith v2.8: connectivity dropped mid-part. Stop the parts
	/// and park the whole download as waiting-for-internet — never
	/// fail over (the single-connection task would just fail too
	/// with no route) and never fail the download. The manifest is
	/// persisted here, and again by _finish, so resume continues
	/// from the per-part byte counts.
	func _parkAsWaitingForInternet(generation: Int) {
		lock.lock()
		if _didFailOver || _isDead || generation != _generation {
			lock.unlock()
			return
		}
		_cancelled = true
		let tasks = partTasks
		lock.unlock()
		for task in tasks {
			task.cancel()
		}
		_cancelDataTasks()
		_persistManifest()
		Task { @MainActor in
			download.isWaitingForInternet = true
			download.status = .paused
		}
		DownloadManager.shared._saveActiveDownloads()
	}
	
	/// Resumes a paused download on the same object (no stale-manifest
	/// race with a second object).
	func resume() {
		lock.lock()
		_cancelled = false
		_failedError = nil
		_didFailOver = false
		_generation += 1
		lock.unlock()
		Task { @MainActor in
			download.status = .downloading
			download.errorMessage = nil
		}
		Task { await start() }
	}
	
	/// Cancels for good: stops the parts and deletes the temp file and
	/// the manifest. _finish becomes a no-op afterwards.
	func cancel() {
		lock.lock()
		_isDead = true
		_cancelled = true
		_generation += 1
		let tasks = partTasks
		lock.unlock()
		for task in tasks {
			task.cancel()
		}
		_cancelDataTasks()
		lock.lock()
		try? fileHandle?.close()
		fileHandle = nil
		lock.unlock()
		_deleteTempAndManifest()
	}
	
	private func _launchPart(_ index: Int, generation: Int) {
		let task = Task {
			await self._runPart(index, generation: generation)
		}
		lock.lock()
		partTasks.append(task)
		lock.unlock()
	}
	
	private func _runPart(_ index: Int, generation: Int) async {
		let start = Int64(index) * _partSize
		let end = min(start + _partSize - 1, totalBytes - 1)
		let offset = start + _partDownloaded(index)
		guard offset <= end else { return }
		// Paused again before this part launched: do not launch.
		if _isCancelled() { return }

		var request = URLRequest(url: url)
		request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
		request.setValue(DownloadManager.browserUserAgent, forHTTPHeaderField: "User-Agent")
		if let cookie = DownloadManager.shared._cookieHeaderValue(for: download) {
			request.setValue(cookie, forHTTPHeaderField: "Cookie")
		}

		// Chunked delivery via a data task with this object as the
		// delegate (see the URLSessionDataDelegate methods below).
		// The old code used `session.bytes(for:)` and iterated it
		// one UInt8 at a time — every byte an async-iterator step
		// — which caps real throughput in the low MB/s: that is
		// the "speed drops to megabits" on big files (the
		// multipart path IS the big-file path). didReceive delivers
		// real Data chunks instead, at full line speed.
		let dataTask = session.dataTask(with: request)
		let taskIdentifier = dataTask.taskIdentifier
		lock.lock()
		_partDataTasks[index] = dataTask
		_partTaskInfo[taskIdentifier] = (partIndex: index, generation: generation)
		lock.unlock()
		do {
			try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
					self._storeContinuation(continuation, taskIdentifier: taskIdentifier)
					self._resumeDataTask(partIndex: index)
				}
			} onCancel: { [weak self] in
				// The part Task was cancelled (pause / cancel /
				// failover): stop the network task too, so its
				// didCompleteWithError resumes the continuation
				// and this part ends instead of hanging.
				self?._cancelDataTask(partIndex: index)
			}
		} catch {
			_unregisterDataTask(partIndex: index, taskIdentifier: taskIdentifier)
			if Task.isCancelled { return }
			// Zenith v2.8: the internet dropped mid-part — park the
			// whole download as waiting-for-internet instead of
			// failing over to the single-connection task, which
			// would just fail too with no route. The manifest is
			// persisted, so resume continues from the per-part
			// byte counts.
			if _isConnectivityError(error) || NetworkMonitor.shared.isOffline {
				_parkAsWaitingForInternet(generation: generation)
				return
			}
			// Any other part failure — truncated byte stream,
			// timeout — falls back to the single-connection
			// download instead of failing the whole download. The
			// single task is the last resort: if it fails too, the
			// download fails honestly through its own delegate.
			_failOverToSingleConnection(generation: generation)
		}
		_unregisterDataTask(partIndex: index, taskIdentifier: taskIdentifier)
	}

	// MARK: - URLSessionDataDelegate (chunked part delivery)

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
		lock.lock()
		let info = _partTaskInfo[dataTask.taskIdentifier]
		lock.unlock()
		guard let info else {
			completionHandler(.cancel)
			return
		}
		guard (response as? HTTPURLResponse)?.statusCode == 206 else {
			// The server claimed ranges but answered with the whole
			// file: fall back to the single-connection task.
			_failOverToSingleConnection(generation: info.generation)
			completionHandler(.cancel)
			return
		}
		completionHandler(.allow)
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		lock.lock()
		let info = _partTaskInfo[dataTask.taskIdentifier]
		let failedOver = _didFailOver
		let dead = _isDead
		lock.unlock()
		guard let info, !failedOver, !dead else { return }
		let offset = Int64(info.partIndex) * _partSize + _partDownloaded(info.partIndex)
		guard _write(data, at: offset, generation: info.generation) else {
			// The part file is unwritable — the single-connection
			// task writes through URLSession's own temp file
			// instead.
			_failOverToSingleConnection(generation: info.generation)
			return
		}
		_addPartDownloaded(info.partIndex, Int64(data.count))
		_reportProgressIfNeeded()
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		lock.lock()
		let continuation = _partContinuations.removeValue(forKey: task.taskIdentifier)
		lock.unlock()
		// No continuation: a stale task, or one whose part already
		// ended — never resume twice.
		guard let continuation else { return }
		if let error {
			continuation.resume(throwing: error)
		} else {
			continuation.resume()
		}
	}

	/// Locked read of the cancelled flag.
	private func _isCancelled() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return _cancelled
	}

	/// Stores the continuation a part Task is suspended in (see
	/// _runPart): kept as a method so the @Sendable awaiting
	/// closures capture only self, never the lock itself.
	private func _storeContinuation(_ continuation: CheckedContinuation<Void, Error>, taskIdentifier: Int) {
		lock.lock()
		_partContinuations[taskIdentifier] = continuation
		lock.unlock()
	}
	
	/// Resumes the live data task for a part (looked up by part
	/// index so the @Sendable awaiting closures never capture the
	/// task itself).
	private func _resumeDataTask(partIndex: Int) {
		lock.lock()
		let dataTask = _partDataTasks[partIndex]
		lock.unlock()
		dataTask?.resume()
	}

	/// Cancels the live data task for a part, if any.
	private func _cancelDataTask(partIndex: Int) {
		lock.lock()
		let dataTask = _partDataTasks[partIndex]
		lock.unlock()
		dataTask?.cancel()
	}

	/// Cancels every live per-part data task (the network side).
	/// Called wherever the part Tasks are cancelled: the Swift
	/// Task cancellation alone does not stop the URLSession task,
	/// and a data task left running would keep writing into the
	/// part file after the pause.
	private func _cancelDataTasks() {
		lock.lock()
		let dataTasks = Array(_partDataTasks.values)
		lock.unlock()
		for dataTask in dataTasks {
			dataTask.cancel()
		}
	}

	/// Drops all bookkeeping for a finished part task.
	private func _unregisterDataTask(partIndex: Int, taskIdentifier: Int) {
		lock.lock()
		_partDataTasks.removeValue(forKey: partIndex)
		_partTaskInfo.removeValue(forKey: taskIdentifier)
		_partContinuations.removeValue(forKey: taskIdentifier)
		lock.unlock()
	}
	
	/// Writes one buffered chunk at its file offset. Returns false
	/// when the part file cannot be written (closed handle or disk
	/// error); the caller fails over to the single-connection task.
	private func _write(_ data: Data, at offset: Int64, generation: Int) -> Bool {
		lock.lock()
		guard let handle = fileHandle else {
			lock.unlock()
			return false
		}
		do {
			try handle.seek(toOffset: UInt64(offset))
			handle.write(data)
		} catch {
			if _failedError == nil {
				_failedError = error
			}
			lock.unlock()
			// Only the current generation may cancel the parts: a
			// stale part failing its write must not kill the parts
			// a resume has just relaunched.
			if generation == _currentGeneration() {
				_cancelAllParts()
			}
			return false
		}
		lock.unlock()
		return true
	}
	
	private func _cancelAllParts() {
		lock.lock()
		let tasks = partTasks
		lock.unlock()
		for task in tasks {
			task.cancel()
		}
		_cancelDataTasks()
	}
	
	private func _failOverToSingleConnection(generation: Int) {
		lock.lock()
		// Never fail over after a pause (manual or connectivity):
		// the download is parked, and a single task started here
		// would be a zombie transport behind the pause. Never on
		// behalf of a stale start() either: a pause/resume since
		// this start() launched means a newer start() owns the
		// download, and failing over here would cancel its parts.
		if _didFailOver || _cancelled || generation != _generation {
			lock.unlock()
			return
		}
		_didFailOver = true
		// A stale part error must not surface later: the single
		// task owns the download from here on.
		_failedError = nil
		let tasks = partTasks
		lock.unlock()
		for task in tasks {
			task.cancel()
		}
		_cancelDataTasks()
		_deleteTempAndManifest()
		Task { @MainActor in
			DownloadManager.shared._startSingleTask(for: download)
		}
	}
	
	private func _finish(generation: Int) async {
		if _isDead { return }
		// Stale start(): a pause/resume/cancel since this start()
		// launched bumped the generation, and a newer start() owns
		// the download now — this finish must not fail over, fail,
		// or complete anything (see _generation).
		if generation != _currentGeneration() { return }
		if _didFailOver { return }
		
		if _cancelled {
			_persistManifest()
			return
		}
		
		if let error = _failedError {
			_persistManifest()
			// Zenith v2.8: a connectivity error surfacing here
			// parks the download as waiting, never fails it.
			if _isConnectivityError(error) || NetworkMonitor.shared.isOffline {
				await MainActor.run {
					download.isWaitingForInternet = true
					download.status = .paused
				}
				DownloadManager.shared._saveActiveDownloads()
				return
			}
			await MainActor.run {
				download.status = .failed
				download.errorMessage = error.localizedDescription
			}
			await MainActor.run {
				DownloadManager.shared._recordHistory(for: download, status: .failed)
			}
			DownloadManager.shared._saveActiveDownloads()
			return
		}
		
		guard _totalDownloaded() >= totalBytes else {
			// Every part ended without an error, but the file is
			// short (the server closed a stream early): fall back
			// to the single-connection download instead of stalling
			// forever on a download that can never complete — unless
			// the internet is gone, in which case park as waiting:
			// a single task started now would just fail too.
			if NetworkMonitor.shared.isOffline {
				_parkAsWaitingForInternet(generation: generation)
				return
			}
			_failOverToSingleConnection(generation: generation)
			return
		}
		
		// All parts done: close, move into place, then either hand
		// to the package flow (.ipa) or complete as a plain file
		// (anything else stays in ZenithDownloads, no install).
		lock.lock()
		try? fileHandle?.close()
		fileHandle = nil
		lock.unlock()
		
		let customTempDir = DownloadManager._finishedDownloadsDirectory()
		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			let destinationURL = customTempDir.appendingPathComponent(download.fileName)
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: tempURL, to: destinationURL)
			_deleteTempAndManifest()
			if download.isIPA {
				await MainActor.run {
					download.status = .completed
				}
				try DownloadManager.shared.handlePachageFile(url: destinationURL, dl: download)
			} else {
				DownloadManager.shared._completeNonIPADownload(download)
			}
		} catch {
			await MainActor.run {
				download.status = .failed
				download.errorMessage = error.localizedDescription
				DownloadManager.shared._recordHistory(for: download, status: .failed)
				DownloadManager.shared._saveActiveDownloads()
			}
		}
	}
	
	private func _reportProgressIfNeeded() {
		var snapshot: Int64?
		lock.lock()
		let now = Date()
		let interval = now.timeIntervalSince(lastReportDate)
		if interval >= 0.25 {
			snapshot = partDownloaded.reduce(0, +)
			lastReportDate = now
		}
		lock.unlock()
		guard let total = snapshot else { return }
		Task { @MainActor in
			download.progress = totalBytes > 0 ? Double(total) / Double(totalBytes) : 0
			download.bytesDownloaded = total
			download.totalBytes = totalBytes
			// Speed + ETA from the same live counts, smoothed
			// (see Download._updateSpeedAndETA) — never the raw
			// per-sample instantaneous value.
			download._updateSpeedAndETA(
				totalDownloaded: total,
				totalBytes: totalBytes,
				now: Date()
			)
			// Zenith v2.10: persist progress + the per-part
			// manifest as the download moves (throttled to one
			// write per 2s inside the manager). Before this the
			// manifest was only written on pause/finish, so a
			// kill mid-download left no offsets on disk and
			// resume restarted from zero.
			if DownloadManager.shared._saveActiveDownloadsThrottled() {
				persistManifest()
			}
		}
	}
	
	private func _persistManifest() {
		let manifest = ZenithMultipartManifest(
			urlString: url.absoluteString,
			totalBytes: totalBytes,
			partCount: partCount,
			partDownloaded: _snapshotPartDownloaded(),
			tempFileName: tempURL.lastPathComponent
		)
		// Atomic: a kill mid-write must never leave a torn
		// manifest behind — an unreadable manifest forces the
		// resume from zero.
		if let data = try? JSONEncoder().encode(manifest) {
			try? data.write(to: manifestURL, options: .atomic)
		}
	}
	
	private func _deleteTempAndManifest() {
		try? FileManager.default.removeItem(at: tempURL)
		try? FileManager.default.removeItem(at: manifestURL)
	}
	
	private func _snapshotPartDownloaded() -> [Int64] {
		lock.lock()
		defer { lock.unlock() }
		return partDownloaded
	}
	
	private func _totalDownloaded() -> Int64 {
		lock.lock()
		defer { lock.unlock() }
		return partDownloaded.reduce(0, +)
	}
	
	private func _partDownloaded(_ index: Int) -> Int64 {
		lock.lock()
		defer { lock.unlock() }
		return partDownloaded[index]
	}
	
	private func _addPartDownloaded(_ index: Int, _ count: Int64) {
		lock.lock()
		defer { lock.unlock() }
		partDownloaded[index] += count
	}
}
