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

class Download: Identifiable, @unchecked Sendable {
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
	
	/// Last speed-sample point, for the throughput window in didWriteData.
	var _speedSampleBytes: Int64 = 0
	var _speedSampleDate: Date?
	
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
	
	let id: String
	let url: URL
	let fileName: String
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
		// the install flow, and give extension-less names the .ipa
		// suffix the installer expects.
		let rawName = (fileName ?? url.lastPathComponent)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let baseName = rawName.isEmpty ? "download.ipa" : rawName
		self.fileName = (baseName as NSString).pathExtension.isEmpty
			? baseName + ".ipa"
			: baseName
	}
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()
	
	@Published var downloads: [Download] = []
	
	/// Finished downloads (completed or failed), newest first, kept on disk.
	@Published var history: [DownloadHistoryEntry] = []
	
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
		let configuration = URLSessionConfiguration.default
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
		_loadHistory()
	}
	
	func startDownload(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		if let existingDownload = downloads.first(where: { $0.url == url }) {
			resumeDownload(existingDownload)
			return existingDownload
		}
		
		let download = Download(id: id, url: url)
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
		} else {
			_updateBackgroundAudioState()
		}
		#endif
		
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
	/// single-connection download.
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
			let tempDirectory = FileManager.default.temporaryDirectory
			let customTempDir = tempDirectory.appendingPathComponent("ZenithDownloads", isDirectory: true)
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			let destinationURL = customTempDir.appendingPathComponent(download.fileName)
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: fileURL, to: destinationURL)
			try handlePachageFile(url: destinationURL, dl: download)
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
		let task = _session.downloadTask(with: request)
		download.task = task
		task.resume()
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
		download.status = .downloading
		download.errorMessage = nil
		// A transport is started below; tell the still-running HEAD
		// probe (if any) not to start a second one.
		download._transportStarted = true
		
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
			download.task = task
			task.resume()
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		} else if let url = download.task?.originalRequest?.url {
			var request = URLRequest(url: url)
			request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
			let task = _session.downloadTask(with: request)
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
	func pauseDownload(_ download: Download) {
		if let multi = download.multipart {
			multi.pause()
			return
		}
		
		guard let task = download.task else {
			download.status = .paused
			return
		}
		
		task.cancel(byProducingResumeData: { [weak self] data in
			if let data {
				self?._saveResumeData(data, for: download.id)
				download.resumeData = data
			}
			Task { @MainActor in
				download.status = .paused
			}
		})
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
	}
	
	private func _saveHistory() {
		try? JSONEncoder().encode(history).write(to: _historyURL)
	}
	
	/// Records a finished download. Keeps the newest 50 entries.
	func _recordHistory(for download: Download, status: DownloadHistoryStatus) {
		let entry = DownloadHistoryEntry(
			id: download.id,
			fileName: download.fileName,
			urlString: download.url.absoluteString,
			date: Date(),
			status: status,
			totalBytes: download.totalBytes
		)
		history.removeAll(where: { $0.id == entry.id })
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
	func retryHistoryEntry(_ entry: DownloadHistoryEntry) {
		guard let url = URL(string: entry.urlString) else { return }
		_ = startDownload(from: url, id: "ZenithManualDownload_\(UUID().uuidString)")
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
		try? data.write(to: _resumeDataURL(for: id))
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
		guard let download = getDownloadTask(by: downloadTask) else { return }
		
		// A 4xx/5xx answer still "finishes" as a download — it is an
		// error page, not the IPA. The same goes for a 200 that
		// serves a web page instead of a file. Fail honestly here
		// instead of feeding an HTML page to the installer.
		if let http = downloadTask.response as? HTTPURLResponse {
			let isErrorPage = !(200...299).contains(http.statusCode)
				|| (http.mimeType?.lowercased().hasPrefix("text/") ?? false)
			if isErrorPage {
				DispatchQueue.main.async {
					download.status = .failed
					download.errorMessage = "HTTP \(http.statusCode)"
					DownloadManager.shared._recordHistory(for: download, status: .failed)
					if let index = DownloadManager.shared.getDownloadIndex(by: download.id) {
						DownloadManager.shared.downloads.remove(at: index)
					}
				}
				return
			}
		}
		
		let tempDirectory = FileManager.default.temporaryDirectory
		let customTempDir = tempDirectory.appendingPathComponent("ZenithDownloads", isDirectory: true)
		
		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			
			// Use the server-suggested filename if available, otherwise fallback
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			let destinationURL = customTempDir.appendingPathComponent(suggestedFileName)
			
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			
			try handlePachageFile(url: destinationURL, dl: download)
		} catch {
			print("Error handling downloaded file: \(error.localizedDescription)")
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
		
		DispatchQueue.main.async {
			download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0
			download.bytesDownloaded = totalBytesWritten
			download.totalBytes = totalBytesExpectedToWrite
			
			// Real throughput + ETA from the live byte counts: a new
			// sample every half second, so the numbers never jump wildly.
			let now = Date()
			if let lastDate = download._speedSampleDate {
				let elapsed = now.timeIntervalSince(lastDate)
				let delta = totalBytesWritten - download._speedSampleBytes
				if elapsed >= 0.5, delta > 0 {
					let speed = Int64(Double(delta) / elapsed)
					download.speedBytesPerSec = speed
					if speed > 0, totalBytesExpectedToWrite > 0 {
						download.estimatedTimeRemaining = TimeInterval(totalBytesExpectedToWrite - totalBytesWritten) / TimeInterval(speed)
					}
					download._speedSampleBytes = totalBytesWritten
					download._speedSampleDate = now
				}
			} else {
				download._speedSampleDate = now
				download._speedSampleBytes = totalBytesWritten
			}
			
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
			}
			#endif
		}
	}
	
	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard
			let error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
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
		
		DispatchQueue.main.async {
			download.status = .failed
			download.errorMessage = error.localizedDescription
			self._recordHistory(for: download, status: .failed)
			
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			}
			
			self._updateBackgroundAudioState()
			#endif
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
}

// MARK: - Multi-connection download

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
final class ZenithMultipartDownload: @unchecked Sendable {
	private let download: Download
	private let url: URL
	private let totalBytes: Int64
	private let partCount: Int
	private let tempURL: URL
	private let manifestURL: URL
	private let session: URLSession
	
	private let lock = NSLock()
	private var partDownloaded: [Int64]
	private var partTasks: [Task<Void, Never>] = []
	private var fileHandle: FileHandle?
	private var startTime = Date()
	private var lastReportDate = Date()
	private var lastReportedBytes: Int64 = 0
	private var _failedError: Error?
	private var _didFailOver = false
	private var _cancelled = false
	private var _isDead = false
	
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
		self.session = URLSession(configuration: .ephemeral)
		if
			let resuming = resumingPartDownloaded,
			resuming.count == self.partCount
		{
			self.partDownloaded = resuming
		} else {
			self.partDownloaded = Array(repeating: 0, count: self.partCount)
		}
	}
	
	static func _multipartDirectory() -> URL {
		FileManager.default.temporaryDirectory
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
		
		startTime = Date()
		lastReportDate = Date()
		lastReportedBytes = _totalDownloaded()
		
		for index in 0..<partCount {
			_launchPart(index)
		}
		
		lock.lock()
		let tasks = partTasks
		lock.unlock()
		for task in tasks {
			await task.value
		}
		await _finish()
	}
	
	/// Pauses: cancels the part tasks; _finish persists the manifest
	/// so resume continues from the per-part byte counts.
	func pause() {
		lock.lock()
		_cancelled = true
		let tasks = partTasks
		lock.unlock()
		for task in tasks {
			task.cancel()
		}
		Task { @MainActor in
			download.status = .paused
		}
	}
	
	/// Resumes a paused download on the same object (no stale-manifest
	/// race with a second object).
	func resume() {
		lock.lock()
		_cancelled = false
		_failedError = nil
		_didFailOver = false
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
		let tasks = partTasks
		lock.unlock()
		for task in tasks {
			task.cancel()
		}
		lock.lock()
		try? fileHandle?.close()
		fileHandle = nil
		lock.unlock()
		_deleteTempAndManifest()
	}
	
	private func _launchPart(_ index: Int) {
		let task = Task {
			await self._runPart(index)
		}
		lock.lock()
		partTasks.append(task)
		lock.unlock()
	}
	
	private func _runPart(_ index: Int) async {
		let start = Int64(index) * _partSize
		let end = min(start + _partSize - 1, totalBytes - 1)
		var offset = start + _partDownloaded(index)
		guard offset <= end else { return }
		
		var request = URLRequest(url: url)
		request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
		request.setValue(DownloadManager.browserUserAgent, forHTTPHeaderField: "User-Agent")
		
		do {
			let (bytes, response) = try await session.bytes(for: request)
			guard (response as? HTTPURLResponse)?.statusCode == 206 else {
				// The server claimed ranges but answered with the whole
				// file: fall back to the single-connection task.
				_failOverToSingleConnection()
				return
			}
			// URLSession.bytes yields single UInt8 values, not Data
			// chunks: collect them into a 64 KB buffer and write the
			// buffer, so the file still lands at the right offsets.
			var buffer = Data()
			buffer.reserveCapacity(64 * 1024)
			for try await byte in bytes {
				try Task.checkCancellation()
				buffer.append(byte)
				if buffer.count >= 64 * 1024 {
					guard _write(buffer, at: offset) else {
						// The part file is unwritable — the
						// single-connection task writes through
						// URLSession's own temp file instead.
						_failOverToSingleConnection()
						return
					}
					offset += Int64(buffer.count)
					_addPartDownloaded(index, Int64(buffer.count))
					buffer.removeAll(keepingCapacity: true)
					_reportProgressIfNeeded()
				}
			}
			if !buffer.isEmpty {
				guard _write(buffer, at: offset) else {
					_failOverToSingleConnection()
					return
				}
				offset += Int64(buffer.count)
				_addPartDownloaded(index, Int64(buffer.count))
				_reportProgressIfNeeded()
			}
		} catch {
			if Task.isCancelled { return }
			// Any part failure — dropped connection, truncated byte
			// stream, timeout — falls back to the single-connection
			// download instead of failing the whole download. The
			// single task is the last resort: if it fails too, the
			// download fails honestly through its own delegate.
			_failOverToSingleConnection()
		}
	}
	
	/// Writes one buffered chunk at its file offset. Returns false
	/// when the part file cannot be written (closed handle or disk
	/// error); the caller fails over to the single-connection task.
	private func _write(_ data: Data, at offset: Int64) -> Bool {
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
			_cancelAllParts()
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
	}
	
	private func _failOverToSingleConnection() {
		lock.lock()
		if _didFailOver {
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
		_deleteTempAndManifest()
		Task { @MainActor in
			DownloadManager.shared._startSingleTask(for: download)
		}
	}
	
	private func _finish() async {
		if _isDead { return }
		if _didFailOver { return }
		
		if _cancelled {
			_persistManifest()
			return
		}
		
		if let error = _failedError {
			_persistManifest()
			await MainActor.run {
				download.status = .failed
				download.errorMessage = error.localizedDescription
			}
			await MainActor.run {
				DownloadManager.shared._recordHistory(for: download, status: .failed)
			}
			return
		}
		
		guard _totalDownloaded() >= totalBytes else {
			// Every part ended without an error, but the file is
			// short (the server closed a stream early): fall back
			// to the single-connection download instead of stalling
			// forever on a download that can never complete.
			_failOverToSingleConnection()
			return
		}
		
		// All parts done: close, move into place, hand to the package flow.
		lock.lock()
		try? fileHandle?.close()
		fileHandle = nil
		lock.unlock()
		
		let customTempDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("ZenithDownloads", isDirectory: true)
		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			let destinationURL = customTempDir.appendingPathComponent(download.fileName)
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: tempURL, to: destinationURL)
			_deleteTempAndManifest()
			await MainActor.run {
				download.status = .completed
			}
			try DownloadManager.shared.handlePachageFile(url: destinationURL, dl: download)
		} catch {
			await MainActor.run {
				download.status = .failed
				download.errorMessage = error.localizedDescription
				DownloadManager.shared._recordHistory(for: download, status: .failed)
			}
		}
	}
	
	private func _reportProgressIfNeeded() {
		var snapshot: (total: Int64, speed: Int64, remaining: TimeInterval?)?
		lock.lock()
		let now = Date()
		let interval = now.timeIntervalSince(lastReportDate)
		if interval >= 0.25 {
			let total = partDownloaded.reduce(0, +)
			let speed = interval > 0 ? Int64(Double(total - lastReportedBytes) / interval) : 0
			lastReportedBytes = total
			lastReportDate = now
			let remaining: TimeInterval? = speed > 0
				? TimeInterval(totalBytes - total) / TimeInterval(speed)
				: nil
			snapshot = (total, speed, remaining)
		}
		lock.unlock()
		guard let snapshot else { return }
		Task { @MainActor in
			download.progress = totalBytes > 0 ? Double(snapshot.total) / Double(totalBytes) : 0
			download.bytesDownloaded = snapshot.total
			download.totalBytes = totalBytes
			download.speedBytesPerSec = snapshot.speed
			download.estimatedTimeRemaining = snapshot.remaining
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
		try? JSONEncoder().encode(manifest).write(to: manifestURL)
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
