//
//  DownloadsView.swift
//  Zenith
//
//  Zenith v2.2 — Downloads tab: paste an IPA link, watch live progress
//  (real %, speed and time left from DownloadManager), pause/resume,
//  and download history with retry. All text is Iraqi dialect.

import SwiftUI
import Combine
import NimbleViews

struct DownloadsView: View {
	@StateObject private var _downloadManager = DownloadManager.shared
	
	@State private var _linkText = ""
	@State private var _isProbing = false
	@State private var _isShowingInvalidLink = false
	@State private var _isShowingSlowWarning = false
	@State private var _pendingURL: URL?
	@State private var _pendingSize: Int64 = 0
	@State private var _pendingSpeed: Double = 0
	@State private var _isShowingBrowser = false
	@State private var _browserURL: URL?
	
	var body: some View {
		ZStack {
			StarfieldBackground()
			NBNavigationView(.localized("Downloads")) {
				List {
					Section {
						VStack(alignment: .leading, spacing: 12) {
							TextField(.localized("Paste IPA Link"), text: $_linkText)
								.textInputAutocapitalization(.never)
								.keyboardType(.URL)
								.autocorrectionDisabled()
						
							Button {
								_startDownloadFlow()
							} label: {
								if _isProbing {
									ProgressView()
										.frame(maxWidth: .infinity)
								} else {
									// Sized icon: a bare Label image
									// renders the 96px PNG at full size
									// (the v2.3 giant-arrow bug).
									HStack(spacing: 8) {
										Image("icon-download")
											.resizable()
											.scaledToFit()
											.frame(width: 20, height: 20)
										Text(.localized("Download"))
									}
									.frame(maxWidth: .infinity)
								}
							}
							.buttonStyle(.borderedProminent)
							.disabled(_linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || _isProbing)
						}
						.zenithGlassCard(cornerRadius: 14)
					} header: {
						Text(.localized("Download IPA"))
					} footer: {
						Text(.localized("Paste a direct link to an IPA file and it will download here, then appear in your library."))
					}
				
					if !_downloadManager.downloads.isEmpty {
						Section(.localized("Active Downloads")) {
							ForEach(_downloadManager.downloads) { download in
								DownloadRowView(download: download)
							}
						}
					}
				
					if !_downloadManager.history.isEmpty {
						Section(.localized("Download History")) {
							ForEach(_downloadManager.history) { entry in
								DownloadHistoryRowView(entry: entry)
							}
						
							Button(.localized("Clear History"), role: .destructive) {
								_downloadManager.clearHistory()
							}
						}
					}
				
					if _downloadManager.downloads.isEmpty && _downloadManager.history.isEmpty {
						VStack(spacing: 10) {
							Image("icon-download")
								.resizable()
								.scaledToFit()
								.frame(width: 44, height: 44)
								.opacity(0.6)
							Text(.localized("No Downloads Yet"))
								.font(.headline)
							Text(.localized("Downloaded IPA files will show up here."))
								.font(.subheadline)
								.foregroundStyle(.secondary)
								.multilineTextAlignment(.center)
						}
						.frame(maxWidth: .infinity)
						.padding(.vertical, 32)
						.zenithGlassCard(cornerRadius: 18)
						.listRowBackground(Color.clear)
					}
				}
				// Transparent list so the starfield shows through the gaps
				// between rows; rows themselves stay clear as well.
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.listRowBackground(Color.clear)
			.alert(.localized("Invalid Link"), isPresented: $_isShowingInvalidLink) {
				Button(.localized("OK"), role: .cancel) {}
			} message: {
				Text(.localized("Paste a valid link, like example.com/app.ipa."))
			}
			.sheet(isPresented: $_isShowingBrowser) {
				if let url = _browserURL {
					MiniBrowserView(
						url: url,
						onFileCaptured: { fileURL in
							_isShowingBrowser = false
							_linkText = ""
							DownloadManager.shared.startDownloadFromCapturedFile(
								fileURL,
								originalURL: url,
								id: "ZenithManualDownload_\(UUID().uuidString)"
							)
						},
						onClose: {
							_isShowingBrowser = false
						}
					)
					.ignoresSafeArea()
				}
			}
			.alert(.localized("Slow Connection"), isPresented: $_isShowingSlowWarning) {
				Button(.localized("Cancel"), role: .cancel) {
					_pendingURL = nil
				}
				Button(.localized("Download Anyway")) {
					if let url = _pendingURL {
						_openBrowser(with: url)
						_pendingURL = nil
					}
				}
			} message: {
				Text(verbatim:
					.localized(
						"Slow Connection Warning",
						arguments: _pendingSize.formattedByteCount,
						Int64(_pendingSpeed).formattedByteCount,
						_pendingEstimatedMinutes()
					)
				)
			}
		}
	}
}
	
	/// Minutes the pending download would take at the probed speed.
	private func _pendingEstimatedMinutes() -> Int {
		guard _pendingSpeed > 0 else { return 0 }
		return Int(Double(_pendingSize) / _pendingSpeed / 60)
	}
	
	/// Opens the pasted link in the small in-app browser, where the
	/// user taps the page's own download button (or the link is the
	/// file itself and the browser intercepts it directly). The URL
	/// here is always the shared normalized one, never raw pasted text.
	private func _openBrowser(with url: URL) {
		_browserURL = url
		_isShowingBrowser = true
	}
	
	/// Validates the link, probes the speed for big files, warns when
	/// the connection is slow, then opens the browser for the download.
	private func _startDownloadFlow() {
		guard let url = DownloadManager.normalizedURL(from: _linkText) else {
			_isShowingInvalidLink = true
			return
		}
		
		_isProbing = true
		Task {
			let size = await _downloadManager.probeContentLength(for: url)
			var speed: Double?
			if let size, size > DownloadManager.largeDownloadThreshold {
				speed = await _downloadManager.probeConnectionSpeed(for: url)
			}
			await MainActor.run {
				_isProbing = false
				if
					let size,
					let speed,
					speed < DownloadManager.slowSpeedThreshold
				{
					_pendingURL = url
					_pendingSize = size
					_pendingSpeed = speed
					_isShowingSlowWarning = true
				} else {
					_openBrowser(with: url)
				}
			}
		}
	}
}

// MARK: - Active download row

/// One live download: real % from byte counts, real measured speed,
/// real time left, pause/resume and cancel.
struct DownloadRowView: View {
	let download: Download
	
	@State private var _progress: Double = 0
	@State private var _bytesDownloaded: Int64 = 0
	@State private var _totalBytes: Int64 = 0
	@State private var _speed: Int64 = 0
	@State private var _timeRemaining: TimeInterval?
	@State private var _status: DownloadStatus = .downloading
	@State private var _isAccelerated = false
	
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(download.fileName)
					.font(.subheadline)
					.lineLimit(1)
				Spacer()
				if _isAccelerated {
					Text(.localized("Fast"))
						.font(.caption2)
						.fontWeight(.semibold)
						.foregroundStyle(Color(hex: "#FFC778"))
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(Color(hex: "#FFC778").opacity(0.15), in: Capsule())
				}
				Text(verbatim: "\(Int(_progress * 100))%")
					.font(.subheadline)
					.fontWeight(.semibold)
					.contentTransition(.numericText())
			}
			
			ProgressView(value: _progress)
				.progressViewStyle(.linear)
				.tint(_status == .failed ? .red : Color(hex: "#FFC778"))
			
			HStack {
				if _status == .failed {
					Text(.localized("Download Failed"))
						.foregroundStyle(.red)
				} else if _status == .paused {
					Text(.localized("Paused"))
						.foregroundStyle(.secondary)
				} else if _speed > 0 {
					Text(verbatim: "\(_speed.formattedByteCount)/s")
				}
				Spacer()
				if _totalBytes > 0 {
					Text(verbatim: "\(_bytesDownloaded.formattedByteCount) / \(_totalBytes.formattedByteCount)")
				}
				if let remaining = _timeRemaining, _status == .downloading {
					Text(verbatim: "· \(_formatTimeRemaining(remaining))")
				}
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			.contentTransition(.numericText())
			
			HStack(spacing: 16) {
				if _status == .downloading {
					Button {
						DownloadManager.shared.pauseDownload(download)
					} label: {
						Label(.localized("Pause"), systemImage: "pause.fill")
					}
				} else if _status == .paused || _status == .failed {
					Button {
						DownloadManager.shared.retryDownload(download)
					} label: {
						Label(
							_status == .failed ? .localized("Retry") : .localized("Resume"),
							systemImage: "play.fill"
						)
					}
				}
				
				Button(role: .destructive) {
					DownloadManager.shared.cancelDownload(download)
				} label: {
					Label(.localized("Cancel"), systemImage: "xmark")
				}
				
				Spacer()
			}
			.font(.subheadline)
			.buttonStyle(.borderless)
		}
		.padding(.vertical, 4)
		.zenithGlassCard(cornerRadius: 12)
		.onReceive(download.$progress) { _progress = $0 }
		.onReceive(download.$bytesDownloaded) { _bytesDownloaded = $0 }
		.onReceive(download.$totalBytes) { _totalBytes = $0 }
		.onReceive(download.$speedBytesPerSec) { _speed = $0 }
		.onReceive(download.$estimatedTimeRemaining) { _timeRemaining = $0 }
		.onReceive(download.$status) { _status = $0 }
		.onReceive(download.$isAccelerated) { _isAccelerated = $0 }
	}
	
	private func _formatTimeRemaining(_ interval: TimeInterval) -> String {
		let totalSeconds = Int(interval)
		if totalSeconds < 60 {
			return .localized("Seconds Left (%lld)", arguments: totalSeconds)
		}
		let minutes = totalSeconds / 60
		let seconds = totalSeconds % 60
		return String(format: "%d:%02d", minutes, seconds)
	}
}

// MARK: - History row

struct DownloadHistoryRowView: View {
	let entry: DownloadHistoryEntry
	
	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: entry.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
				.foregroundStyle(entry.status == .completed ? .green : .red)
				.font(.title3)
			
			VStack(alignment: .leading, spacing: 2) {
				Text(entry.fileName)
					.font(.subheadline)
					.lineLimit(1)
				HStack(spacing: 4) {
					Text(entry.date, style: .date)
					if entry.totalBytes > 0 {
						Text(verbatim: "· \(entry.totalBytes.formattedByteCount)")
					}
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			}
			
			Spacer()
			
			if entry.status == .failed {
				Button(.localized("Retry")) {
					DownloadManager.shared.retryHistoryEntry(entry)
				}
				.buttonStyle(.borderless)
				.font(.subheadline)
			}
		}
		.padding(.vertical, 2)
		.zenithGlassCard(cornerRadius: 12)
	}
}
