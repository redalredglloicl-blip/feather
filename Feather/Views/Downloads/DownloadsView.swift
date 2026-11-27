//
//  DownloadsView.swift
//  Zenith
//
//  Zenith v2.2 — Downloads tab: paste a file link, watch live progress
//  (real %, speed and time left from DownloadManager), pause/resume,
//  and download history with retry. All text is Iraqi dialect.

import SwiftUI
import Combine
import QuickLook
import NimbleViews

struct DownloadsView: View {
	@StateObject private var _downloadManager = DownloadManager.shared
	// Zenith v2.12 item 5: the Backups list lives on this tab.
	@StateObject private var _backupManager = BackupManager.shared
	
	@State private var _linkText = ""
	@State private var _isProbing = false
	@State private var _isShowingInvalidLink = false
	@State private var _isShowingSlowWarning = false
	@State private var _pendingURL: URL?
	@State private var _pendingSize: Int64 = 0
	@State private var _pendingSpeed: Double = 0
	@State private var _isShowingBrowser = false
	@State private var _browserURL: URL?
	/// Backup waiting for the user to confirm its deletion.
	@State private var _backupPendingDelete: ZenithBackup?
	/// Backup whose restore was just started (notice alert).
	@State private var _restoredBackupName = ""
	@State private var _isShowingRestoreNotice = false
	
	var body: some View {
		NBNavigationView(.localized("Downloads")) {
			List {
				Section {
					VStack(alignment: .leading, spacing: 16) {
						TextField(.localized("Paste File Link"), text: $_linkText)
							.textFieldStyle(.plain)
							.textInputAutocapitalization(.never)
							.keyboardType(.URL)
							.autocorrectionDisabled()
							.padding(.vertical, 10)
							.padding(.horizontal, 12)
							.background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
						
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
					.padding(.horizontal, 16)
					.listRowInsets(EdgeInsets())
					.listRowBackground(Color.clear)
					.listRowSeparator(.hidden)
				} header: {
					Text(.localized("Download File"))
				} footer: {
					Text(.localized("Paste a direct link to any file and it will download here. IPA files appear in your library."))
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
			
				// Zenith v2.12 item 5: copies of the original app,
				// saved before signing or modding. Restore puts the
				// original back in the Library; Delete is the only
				// way a backup is ever removed.
				if !_backupManager.backups.isEmpty {
					Section(.localized("Backups")) {
						ForEach(_backupManager.backups) { backup in
							BackupRowView(
								backup: backup,
								onRestore: {
									_backupManager.restore(backup)
									_restoredBackupName = backup.appName
									_isShowingRestoreNotice = true
								},
								onDelete: {
									_backupPendingDelete = backup
								}
							)
						}
					} footer: {
						Text(.localized("Backups Footer"))
					}
				}
			
				// Zenith v2.12 item 7: OFF by default — when ON, a
				// finished download offers the system export picker
				// so the user picks where in Files it goes.
				Section(.localized("Save to Files")) {
					Toggle(.localized("Ask to save to Files after download"), isOn: $_downloadManager.askToSaveToFilesAfterDownload)
				} footer: {
					Text(.localized("Save to Files Footer"))
				}
			
				if _downloadManager.downloads.isEmpty && _downloadManager.history.isEmpty {
					VStack(spacing: 16) {
						Image("icon-download")
							.resizable()
							.scaledToFit()
							.frame(width: 44, height: 44)
							.opacity(0.6)
						Text(.localized("No Downloads Yet"))
							.font(.headline)
						Text(.localized("Downloaded files will show up here."))
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
			// Starfield sits directly on the List (like the
			// Certificates ScrollView) so the stars show through the
			// gaps between rows; rows themselves stay clear as well.
			.scrollContentBackground(.hidden)
			.background(Color.clear)
			.starfieldBackground()
			.listRowBackground(Color.clear)
		}
		.alert(.localized("Invalid Link"), isPresented: $_isShowingInvalidLink) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(.localized("Paste a valid link, like example.com/file.zip."))
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
					onDownloadURLCaptured: { capturedURL, cookies in
						_isShowingBrowser = false
						_linkText = ""
						_ = DownloadManager.shared.startDownload(
							from: capturedURL,
							id: "ZenithManualDownload_\(UUID().uuidString)",
							cookies: cookies
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
		// Zenith v2.12 item 7: the system export picker for the
		// pending finished file — manual "Save to Files" tap, or
		// automatic when the toggle is ON. Dismiss (pick or
		// cancel) clears the pending file; the original always
		// stays in the app's downloads dir.
		.sheet(isPresented: Binding(
			get: { _downloadManager.fileAwaitingSave != nil },
			set: { isPresented in
				if !isPresented { _downloadManager.dismissSavePrompt() }
			}
		)) {
			if let fileURL = _downloadManager.fileAwaitingSave {
				DocumentExportPicker(fileURL: fileURL) {
					_downloadManager.dismissSavePrompt()
				}
			}
		}
		// Zenith v2.12 item 5: confirm before a backup is deleted —
		// deletion is the only way a backup is ever removed.
		.alert(item: $_backupPendingDelete) { backup in
			Alert(
				title: Text(.localized("Delete Backup")),
				message: Text(verbatim: .localized("Delete Backup Confirm", arguments: backup.appName)),
				primaryButton: .destructive(Text(.localized("Delete"))) {
					_backupManager.delete(backup)
				},
				secondaryButton: .cancel()
			)
		}
		.alert(.localized("Restoring Backup"), isPresented: $_isShowingRestoreNotice) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(verbatim: .localized("Restoring Backup Message", arguments: _restoredBackupName))
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
	/// The live download object, observed directly: every @Published
	/// change (status, progress, speed) re-renders this row at once,
	/// so pause/resume/cancel show immediately. The old @State mirror
	/// + onReceive chain could only show what its subscriptions
	/// delivered, one property at a time, and the Pause/Resume button
	/// itself was gated on the mirrored copy.
	@ObservedObject var download: Download

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Text(download.fileName)
					.font(.subheadline)
					.lineLimit(1)
				Spacer()
				if download.isAccelerated {
					Text(.localized("Fast"))
						.font(.caption2)
						.fontWeight(.semibold)
						.foregroundStyle(Color(hex: "#FFC778"))
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(Color(hex: "#FFC778").opacity(0.15), in: Capsule())
				}
				Text(verbatim: "\(Int(download.progress * 100))%")
					.font(.subheadline)
					.fontWeight(.semibold)
					.contentTransition(.numericText())
			}
			
			ProgressView(value: download.progress)
				.progressViewStyle(.linear)
				.tint(download.status == .failed ? .red : Color(hex: "#FFC778"))
			
			HStack {
				if download.status == .failed {
					Text(.localized("Download Failed"))
						.foregroundStyle(.red)
				} else if download.isWaitingForInternet {
					// Zenith v2.8: auto-paused for lost internet —
					// never a failure state. The download resumes
					// itself when the internet returns.
					Text(.localized("Waiting for Internet"))
						.foregroundStyle(.secondary)
				} else if download.status == .paused {
					Text(.localized("Paused"))
						.foregroundStyle(.secondary)
				} else {
					// Downloading: the smoothed real speed; "—"
					// while nothing is moving yet (waiting, not 0).
					Text(verbatim: download.speedBytesPerSec > 0 ? _formatSpeed(download.speedBytesPerSec) : "—")
				}
				Spacer()
				if download.totalBytes > 0 {
					Text(verbatim: "\(download.bytesDownloaded.formattedByteCount) / \(download.totalBytes.formattedByteCount)")
				}
				if let remaining = download.estimatedTimeRemaining, download.status == .downloading {
					Text(verbatim: "· \(_formatTimeRemaining(remaining))")
				} else if download.status == .downloading, download.totalBytes > 0 {
					// No usable speed yet: waiting, never a huge
					// number from dividing by ~0.
					Text(verbatim: "· —")
				}
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			.contentTransition(.numericText())
			
			HStack(spacing: 16) {
				if download.status == .downloading {
					Button {
						DownloadManager.shared.pauseDownload(download)
					} label: {
						Label(.localized("Pause"), systemImage: "pause.fill")
					}
					.buttonStyle(.borderless)
				} else if download.status == .paused || download.status == .failed {
					Button {
						DownloadManager.shared.retryDownload(download)
					} label: {
						Label(
							download.status == .failed ? .localized("Retry") : .localized("Resume"),
							systemImage: "play.fill"
						)
					}
					.buttonStyle(.borderless)
				}

				Button(role: .destructive) {
					DownloadManager.shared.cancelDownload(download)
				} label: {
					Label(.localized("Cancel"), systemImage: "xmark")
				}
				.buttonStyle(.borderless)

				Spacer()
			}
			.font(.subheadline)
		}
		.padding(.vertical, 4)
		.zenithGlassCard(cornerRadius: 12)
	}
	
	/// Real measured throughput, formatted for the row: one
	/// decimal in MB/s at/above 1 MB/s, whole KB/s below that,
	/// whole B/s at the bottom. Decimal units (1 MB = 1,000,000
	/// bytes), matching the file sizes in the same row
	/// (ByteCountFormatter .file). The value is the smoothed
	/// speed from DownloadManager — never inflated.
	private func _formatSpeed(_ bytesPerSec: Int64) -> String {
		if bytesPerSec >= 1_000_000 {
			return String(format: "%.1f MB/s", Double(bytesPerSec) / 1_000_000)
		} else if bytesPerSec >= 1_000 {
			return "\(bytesPerSec / 1_000) KB/s"
		} else {
			return "\(bytesPerSec) B/s"
		}
	}
	
	private func _formatTimeRemaining(_ interval: TimeInterval) -> String {
		let totalSeconds = Int(interval)
		if totalSeconds < 60 {
			return .localized("Seconds Left (%lld)", arguments: totalSeconds)
		}
		if totalSeconds >= 3600 {
			let hours = totalSeconds / 3600
			let minutes = (totalSeconds % 3600) / 60
			let seconds = totalSeconds % 60
			return String(format: "%d:%02d:%02d", hours, minutes, seconds)
		}
		let minutes = totalSeconds / 60
		let seconds = totalSeconds % 60
		return String(format: "%d:%02d", minutes, seconds)
	}
}

// MARK: - History row

struct DownloadHistoryRowView: View {
	let entry: DownloadHistoryEntry
	
	@State private var _fileToPreview: URL?
	@State private var _isShowingPreview = false
	
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
			
			if entry.status == .completed,
			   let fileURL = DownloadManager.shared.downloadedFileURL(for: entry) {
				// Zenith v2.12 item 7: per-download "Save to Files"
				// — the system export picker, for any finished file
				// including IPAs. The original stays in place.
				Button(.localized("Save to Files")) {
					DownloadManager.shared.requestSaveToFiles(fileURL: fileURL)
				}
				.buttonStyle(.borderless)
				.font(.subheadline)
				if !_isIPAFile(entry.fileName) {
					Button(.localized("Share")) {
						UIActivityViewController.show(activityItems: [fileURL])
					}
					.buttonStyle(.borderless)
					.font(.subheadline)
					Button(.localized("Preview")) {
						_fileToPreview = fileURL
						_isShowingPreview = true
					}
					.buttonStyle(.borderless)
					.font(.subheadline)
				}
			} else if entry.status == .failed {
				Button(.localized("Retry")) {
					DownloadManager.shared.retryHistoryEntry(entry)
				}
				.buttonStyle(.borderless)
				.font(.subheadline)
			}
		}
		.padding(.vertical, 2)
		.zenithGlassCard(cornerRadius: 12)
		.sheet(isPresented: $_isShowingPreview) {
			if let fileURL = _fileToPreview {
				FilePreviewView(fileURL: fileURL)
			}
		}
	}
	
	/// IPA files go through the signing/library flow, never the
	/// generic share/preview buttons.
	private func _isIPAFile(_ fileName: String) -> Bool {
		URL(fileURLWithPath: fileName).pathExtension.lowercased() == "ipa"
	}
}

// MARK: - File preview (QuickLook)

/// System QuickLook preview for a downloaded non-IPA file, wrapped
/// in a navigation controller so there is a Done button to dismiss.
/// Only ever created for a file that exists on disk — the history
/// row checks `downloadedFileURL(for:)` before showing the button.
struct FilePreviewView: UIViewControllerRepresentable {
	let fileURL: URL
	
	func makeCoordinator() -> FilePreviewCoordinator {
		FilePreviewCoordinator(fileURL: fileURL)
	}
	
	func makeUIViewController(context: Context) -> UINavigationController {
		let preview = QLPreviewController()
		preview.dataSource = context.coordinator
		preview.navigationItem.rightBarButtonItem = UIBarButtonItem(
			barButtonSystemItem: .done,
			target: context.coordinator,
			action: #selector(FilePreviewCoordinator.dismissPreview)
		)
		let navigation = UINavigationController(rootViewController: preview)
		context.coordinator.navigationController = navigation
		return navigation
	}
	
	func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

final class FilePreviewCoordinator: NSObject, QLPreviewControllerDataSource {
	let fileURL: URL
	weak var navigationController: UINavigationController?
	
	init(fileURL: URL) {
		self.fileURL = fileURL
	}
	
	func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
		1
	}
	
	func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
		fileURL as QLPreviewItem
	}
	
	@objc func dismissPreview() {
		navigationController?.dismiss(animated: true)
	}
}

// MARK: - Backup row (Zenith v2.12 item 5)

/// One saved original: app name, backup date and size, with
/// Restore (re-imports the backup IPA into the Library) and
/// Delete (the only way a backup is ever removed).
struct BackupRowView: View {
	let backup: ZenithBackup
	let onRestore: () -> Void
	let onDelete: () -> Void
	
	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "archivebox.fill")
				.foregroundStyle(Color(hex: "#FFC778"))
				.font(.title3)
			
			VStack(alignment: .leading, spacing: 2) {
				Text(backup.appName)
					.font(.subheadline)
					.lineLimit(1)
				HStack(spacing: 4) {
					Text(backup.date, style: .date)
					Text(verbatim: "· \(backup.sizeBytes.formattedByteCount)")
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			}
			
			Spacer()
			
			Button(.localized("Restore")) {
				onRestore()
			}
			.buttonStyle(.borderless)
			.font(.subheadline)
			
			Button(.localized("Delete"), role: .destructive) {
				onDelete()
			}
			.buttonStyle(.borderless)
			.font(.subheadline)
		}
		.padding(.vertical, 2)
		.zenithGlassCard(cornerRadius: 12)
	}
}

// MARK: - System export picker (Zenith v2.12 item 7)

/// The system export picker — the ONLY way a finished file leaves
/// the sandbox: the user picks where in Files it goes (On My iPhone
/// / iCloud Drive) or dismisses. `asCopy: true` keeps the original
/// in the app's downloads dir. Pick or cancel always calls
/// onDismiss, so the pending file is cleared either way.
struct DocumentExportPicker: UIViewControllerRepresentable {
	let fileURL: URL
	let onDismiss: () -> Void
	
	func makeCoordinator() -> Coordinator {
		Coordinator(onDismiss: onDismiss)
	}
	
	func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
		let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
		picker.delegate = context.coordinator
		return picker
	}
	
	func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
	
	final class Coordinator: NSObject, UIDocumentPickerDelegate {
		let onDismiss: () -> Void
		
		init(onDismiss: @escaping () -> Void) {
			self.onDismiss = onDismiss
		}
		
		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			onDismiss()
		}
		
		func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
			onDismiss()
		}
	}
}
