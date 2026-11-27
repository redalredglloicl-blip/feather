//
//  BackgroundTaskManager.swift
//  Zenith
//
//  Created by Nagata Asami on 4/1/26.
//

#if !targetEnvironment(macCatalyst)

import Foundation
import BackgroundTasks
import CryptoKit

@available(iOS 26.0, *)
class BackgroundTaskManager: ObservableObject {
	static let shared = BackgroundTaskManager()
	
	private let baseId = "\(Bundle.main.bundleIdentifier!).userTask"
	
	private var activeTasks: [String: BGContinuedProcessingTask] = [:]
	private var registeredTasks: Set<String> = []
	/// Identifiers already submitted and not yet finished/expired:
	/// a second submit for the same identifier is rejected by the
	/// scheduler, and resumeDownload re-submits on every resume.
	private var submittedTasks: Set<String> = []
	
	func startTask(for downloadId: String, filename: String) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		
		// Already running (or already submitted) for this download:
		// do not submit a second request for the same identifier.
		if activeTasks[taskIdentifier] != nil || submittedTasks.contains(taskIdentifier) {
			return
		}
		
		if !registeredTasks.contains(taskIdentifier) {
			BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
				guard let task = task as? BGContinuedProcessingTask else { return }
				self.activeTasks[task.identifier] = task
				
				task.expirationHandler = {
					if let download = DownloadManager.shared.getDownload(by: downloadId) {
						if download.multipart != nil {
							// Multi-connection parts run on an
							// ephemeral session in the app process:
							// they die when the app suspends, so
							// pause now — the manifest persists and
							// the download resumes from its part
							// offsets. (Zenith v2.11: never cancel
							// here — cancelling removed the download
							// and deleted its resume state, so a
							// backgrounded download vanished.)
							DownloadManager.shared.pauseDownload(download)
						} else {
							// Single-connection downloads run on the
							// background URLSession: the system
							// daemon keeps fetching after the app
							// suspends, so do NOT pause — pausing
							// here would cancel the daemon task and
							// throw the download back to a
							// resume-data gamble. Just persist a
							// snapshot of where it stands.
							DownloadManager.shared._saveActiveDownloads()
						}
					}
					self.activeTasks.removeValue(forKey: task.identifier)
					self.submittedTasks.remove(task.identifier)
				}
			}
			self.registeredTasks.insert(taskIdentifier)
		}
		
		let request = BGContinuedProcessingTaskRequest(identifier: taskIdentifier, title: filename, subtitle: .localized("Downloading"))
		request.strategy = .queue
		do {
			try BGTaskScheduler.shared.submit(request)
			self.submittedTasks.insert(taskIdentifier)
		} catch {
			print(error)
		}
	}
	
	func updateProgress(for downloadId: String, progress: Double) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		
		guard let task = activeTasks[taskIdentifier] else { return }
		task.progress.totalUnitCount = 100
		task.progress.completedUnitCount = Int64(progress * 100)
		
		task.updateTitle(task.title, subtitle: "\(Int(progress * 100))%")
		
		if task.progress.completedUnitCount == task.progress.totalUnitCount {
			stopTask(for: downloadId, success: true)
		}
	}
	
	func stopTask(for downloadId: String, success: Bool) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		guard let task = activeTasks[taskIdentifier] else { return }
		
		task.setTaskCompleted(success: success)
		activeTasks.removeValue(forKey: taskIdentifier)
		submittedTasks.remove(taskIdentifier)
	}
}

extension String {
	var md5: String {
		Insecure.MD5.hash(data: Data(self.utf8)).map { String(format: "%02hhx", $0) }.joined()
	}
}

#endif
