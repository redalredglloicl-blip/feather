//
//  SigningQueueManager.swift
//  Zenith
//
//  Zenith v2.2 — batch signing queue: signs several IPAs one after
//  another through the existing Zenith.signPackageFile entry point. No
//  signing engine code lives here — this only sequences the calls and
//  tracks each item's real status.

import Foundation
import Combine

enum SigningQueueStatus {
	case waiting
	case signing
	case done
	case failed
}

final class SigningQueueItem: Identifiable, ObservableObject {
	let id = UUID()
	let app: any AppInfoPresentable
	@Published var status: SigningQueueStatus = .waiting
	@Published var errorMessage: String?
	
	init(app: any AppInfoPresentable) {
		self.app = app
	}
}

final class SigningQueueManager: ObservableObject {
	static let shared = SigningQueueManager()
	
	@Published var items: [SigningQueueItem] = []
	@Published var isRunning = false
	@Published var showNoCertificateAlert = false
	
	/// Real overall progress: signed count out of queued count.
	var doneCount: Int {
		items.filter { $0.status == .done }.count
	}
	
	var failedCount: Int {
		items.filter { $0.status == .failed }.count
	}
	
	func enqueue(_ apps: [any AppInfoPresentable]) {
		for app in apps {
			guard !items.contains(where: { $0.app.uuid == app.uuid && $0.status != .done }) else { continue }
			items.append(SigningQueueItem(app: app))
		}
	}
	
	func remove(_ item: SigningQueueItem) {
		items.removeAll(where: { $0.id == item.id })
	}
	
	func clearFinished() {
		items.removeAll(where: { $0.status == .done })
	}
	
	func retry(_ item: SigningQueueItem) {
		item.status = .waiting
		item.errorMessage = nil
		start()
	}
	
	/// The certificate the queue signs with: the default one, or the
	/// first imported one. Same rule as the single-sign sheet.
	func defaultCertificate() -> CertificatePair? {
		let certs = Storage.shared.getAllCertificates()
		return certs.first(where: { $0.isDefault }) ?? certs.first
	}
	
	func start() {
		guard !isRunning else { return }
		
		if
			defaultCertificate() == nil,
			OptionsManager.shared.options.signingOption == .default
		{
			showNoCertificateAlert = true
			return
		}
		
		isRunning = true
		Task {
			for item in items where item.status == .waiting || item.status == .failed {
				await MainActor.run {
					item.status = .signing
					item.errorMessage = nil
				}
				let error = await _sign(item.app)
				await MainActor.run {
					if let error {
						item.status = .failed
						item.errorMessage = error.localizedDescription
					} else {
						item.status = .done
					}
				}
			}
			await MainActor.run {
				isRunning = false
			}
		}
	}
	
	/// One item through the existing sign entry point. Signing reports
	/// no percentage, so the queue shows status per item plus the real
	/// overall count — never a made-up %.
	private func _sign(_ app: any AppInfoPresentable) async -> Error? {
		await withCheckedContinuation { continuation in
			Zenith.signPackageFile(
				app,
				using: OptionsManager.shared.options,
				icon: nil,
				certificate: defaultCertificate()
			) { error in
				continuation.resume(returning: error)
			}
		}
	}
}
