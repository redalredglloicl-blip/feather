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
	
	func startTask(for downloadId: String, filename: String) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		
		if !registeredTasks.contains(taskIdentifier) {
			BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
				guard let task = task as? BGContinuedProcessingTask else { return }
				self.activeTasks[task.identifier] = task
				
				task.expirationHandler = {
					if let download = DownloadManager.shared.getDownload(by: downloadId) {
						// Zenith v2.11: expiry is the system reclaiming
						// background time, NOT a user cancel. Cancelling
						// here removed the download from the list (and
						// the $downloads sink then persisted [] over
						// ZenithActiveDownloads.json) and deleted its
						// resume data + multipart manifest — so a
						// download that was backgrounded for a while
						// vanished with no history entry, and the
						// Downloads tab showed "no downloads yet" on
						// the next launch. Pause instead: the entry,
						// its real progress and its resume state all
						// survive, and the user resumes it by hand.
						DownloadManager.shared.pauseDownload(download)
					}
					self.activeTasks.removeValue(forKey: task.identifier)
				}
			}
			self.registeredTasks.insert(taskIdentifier)
		}
		
		let request = BGContinuedProcessingTaskRequest(identifier: taskIdentifier, title: filename, subtitle: .localized("Downloading"))
		request.strategy = .queue
		do {
			try BGTaskScheduler.shared.submit(request)
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
	}
}

extension String {
	var md5: String {
		Insecure.MD5.hash(data: Data(self.utf8)).map { String(format: "%02hhx", $0) }.joined()
	}
}

#endif
