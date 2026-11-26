//
//  ZenithApp.swift
//  Zenith
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import Nuke
import IDeviceSwift
import OSLog

@main
struct ZenithApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	
	let heartbeat = HeartbeatManager.shared
	
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject private var _forcedUpdate = ForcedUpdateManager.shared
	@StateObject private var _networkMonitor = NetworkMonitor.shared
	@StateObject private var _newVersionNotifier = NewVersionNotifier.shared
	@State private var _launchBounced = false
	@State private var _startupDone = false
	let storage = Storage.shared
	
	var body: some Scene {
		WindowGroup {
			Group {
				if _networkMonitor.isOffline {
					OfflineBlockView()
				} else if _forcedUpdate.isUpdateRequired {
					ForcedUpdateView()
				} else if !_startupDone {
					// Zenith v2.2: real startup screen — the counter is
					// driven by the actual init steps in LoadingView
					// (storage, certificates, reminders, update check),
					// never a fake timer. The forced-update gate above
					// is untouched: a cached block still wins first.
					LoadingView {
						_startupDone = true
					}
				} else {
					VStack {
				DownloadHeaderView(downloadManager: downloadManager)
					.transition(.move(edge: .top).combined(with: .opacity))
				if _newVersionNotifier.showBanner {
					NewVersionBannerView(notifier: _newVersionNotifier)
				}
				VariedTabbarView()
					.environment(\.managedObjectContext, storage.context)
					.onOpenURL(perform: _handleURL)
					.transition(.move(edge: .top).combined(with: .opacity))
					// Zenith: light launch bounce, once only, on first appear.
					.scaleEffect(_launchBounced ? 1 : 0.97)
					.opacity(_launchBounced ? 1 : 0)
					.onAppear {
						withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
							_launchBounced = true
						}
					}
			}
			.animation(.smooth, value: downloadManager.manualDownloads.description)
			.onReceive(NotificationCenter.default.publisher(for: .heartbeatInvalidHost)) { _ in
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(
						title: "InvalidHostID",
						message: .localized("Your pairing file is invalid and is incompatible with your device, please import a valid pairing file.")
					)
				}
			}
			// dear god help me
			.onAppear {
				// Expiry reminders: ask once, then re-schedule for all stored certificates.
				NotificationManager.shared.requestAuthorization()
				Storage.shared.getAllCertificates().forEach {
					NotificationManager.shared.scheduleExpiryReminders(for: $0)
				}
				// Keep a background refresh scheduled on every launch.
				AutoRefreshManager.shared.scheduleBackgroundRefresh()
				
				// Zenith: fixed theme — dark mode + peach accent, no user choice.
				UIApplication.topViewController()?.view.window?.overrideUserInterfaceStyle = .dark
				UIApplication.topViewController()?.view.window?.tintColor = UIColor(Color(hex: "#FFC778"))
				// Zenith: reset any stored v1 appearance choices so old tinted/dynamic icons cannot survive.
				UserDefaults.standard.removeObject(forKey: "Zenith.userInterfaceStyle")
				UserDefaults.standard.removeObject(forKey: "Zenith.shouldTintIcons")
				UserDefaults.standard.removeObject(forKey: "Zenith.shouldChangeIconsBasedOffStyle")
				UserDefaults.standard.set("#FFC778", forKey: "Zenith.userTintColor")
				// Zenith v2.2: share the selected certificate with the home-screen widget.
				WidgetDataStore.shared.sync()
			}
				}
			}
			.task {
				// Zenith v2.3: no-internet gate — start watching connectivity.
				NetworkMonitor.shared.start()
				// Zenith forced update: check on every launch.
				await ForcedUpdateManager.shared.checkForUpdate()
				// Zenith v2.2: notify once if a newer build was released.
				await NewVersionNotifier.shared.checkForNewVersion()
			}
			.onChange(of: _networkMonitor.isOffline) { isOffline in
				// Back online after being blocked: the update check
				// ran while offline and failed open, so check again now.
				if !isOffline {
					Task {
						await ForcedUpdateManager.shared.checkForUpdate()
						await NewVersionNotifier.shared.checkForNewVersion()
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
				Task {
					await ForcedUpdateManager.shared.checkForUpdate()
					await NewVersionNotifier.shared.checkForNewVersion()
					WidgetDataStore.shared.sync()
				}
			}
		}
	}
	
	private func _handleURL(_ url: URL) {
		if url.scheme == "zenith" {
			/// zenith://import-certificate?p12=<base64>&mobileprovision=<base64>&password=<base64>
			if url.host == "import-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
					let queryItems = components.queryItems
				else {
					return
				}
				
				func queryValue(_ name: String) -> String? {
					queryItems.first(where: { $0.name == name })?.value?.removingPercentEncoding
				}
				
				guard
					let p12Base64 = queryValue("p12"),
					let provisionBase64 = queryValue("mobileprovision"),
					let passwordBase64 = queryValue("password"),
					let passwordData = Data(base64Encoded: passwordBase64),
					let password = String(data: passwordData, encoding: .utf8)
				else {
					return
				}
				
				let generator = UINotificationFeedbackGenerator()
				generator.prepare()
				
				guard
					let p12URL = FileManager.default.decodeAndWrite(base64: p12Base64, pathComponent: ".p12"),
					let provisionURL = FileManager.default.decodeAndWrite(base64: provisionBase64, pathComponent: ".mobileprovision"),
					Zenith.checkPasswordForCertificate(for: p12URL, with: password, using: provisionURL)
				else {
					generator.notificationOccurred(.error)
					return
				}
				
				Zenith.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: password
				) { error in
					if let error = error {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					} else {
						generator.notificationOccurred(.success)
					}
				}
				
				return
			}
			/// zenith://export-certificate?callback_template=<template>
			/// ?callback_template=: This is how we callback to the application requesting the certificate, this will be a url scheme
			/// 	example: livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29
			/// 	decoded: livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)
			/// $(BASE64_CERT) and $(PASSWORD) must be presenting in the callback template so we can replace them with the proper content
			if url.host == "export-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				else {
					return
				}
				
				let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
				guard let callbackTemplate = queryItems["callback_template"]?.removingPercentEncoding else { return }
				
				Zenith.exportCertificateAndOpenUrl(using: callbackTemplate)
			}
			/// zenith://install/<url.ipa>
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath)
			{
				UIAlertController.showAlertWithCancel(
					title: .localized("Install"),
					message: .localized("Do you want to download and install this file?") + "\n\n\(downloadURL)",
					actions: [
						UIAlertAction(title: .localized("Install"), style: .default) { _ in
							_ = DownloadManager.shared.startDownload(from: downloadURL)
						}
					]
				)
			}
		} else {
			if url.pathExtension == "ipa" || url.pathExtension == "tipa" {
				if FileManager.default.isFileFromFileProvider(at: url) {
					guard url.startAccessingSecurityScopedResource() else { return }
					Zenith.handlePackageFile(url) { _ in }
				} else {
					Zenith.handlePackageFile(url) { _ in }
				}
				
				return
			}
		}
	}
}

class AppDelegate: NSObject, UIApplicationDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		_createPipeline()
		_createDocumentsDirectories()
		ResetView.clearWorkCache()
		_addDefaultCertificates()
		// Background auto-refresh: register the task and schedule the
		// next run. Best-effort — iOS decides when it actually runs.
		Task { @MainActor in
			AutoRefreshManager.shared.registerBackgroundRefresh()
			AutoRefreshManager.shared.scheduleBackgroundRefresh()
		}
		return true
	}
	
	private func _createPipeline() {
		DataLoader.sharedUrlCache.diskCapacity = 0
		
		let pipeline = ImagePipeline {
			let dataLoader: DataLoader = {
				let config = URLSessionConfiguration.default
				config.urlCache = nil
				return DataLoader(configuration: config)
			}()
			let dataCache = try? DataCache(name: "com.zenith.app.datacache") // disk cache
			let imageCache = Nuke.ImageCache() // memory cache
			dataCache?.sizeLimit = 500 * 1024 * 1024
			imageCache.costLimit = 100 * 1024 * 1024
			$0.dataCache = dataCache
			$0.imageCache = imageCache
			$0.dataLoader = dataLoader
			$0.dataCachePolicy = .automatic
			$0.isStoringPreviewsInMemoryCache = false
		}
		
		ImagePipeline.shared = pipeline
	}
	
	private func _createDocumentsDirectories() {
		let fileManager = FileManager.default

		let directories: [URL] = [
			fileManager.archives,
			fileManager.certificates,
			fileManager.signed,
			fileManager.unsigned
		]
		
		for url in directories {
			try? fileManager.createDirectoryIfNeeded(at: url)
		}
	}
	
	private func _addDefaultCertificates() {
		guard
			UserDefaults.standard.bool(forKey: "zenith.didImportDefaultCertificates") == false,
			let signingAssetsURL = Bundle.main.url(forResource: "signing-assets", withExtension: nil)
		else {
			return
		}
		
		do {
			let folderContents = try FileManager.default.contentsOfDirectory(
				at: signingAssetsURL,
				includingPropertiesForKeys: nil,
				options: .skipsHiddenFiles
			)
			
			for folderURL in folderContents {
				guard folderURL.hasDirectoryPath else { continue }
				
				let certName = folderURL.lastPathComponent
				
				let p12Url = folderURL.appendingPathComponent("cert.p12")
				let provisionUrl = folderURL.appendingPathComponent("cert.mobileprovision")
				let passwordUrl = folderURL.appendingPathComponent("cert.txt")
				
				guard
					FileManager.default.fileExists(atPath: p12Url.path),
					FileManager.default.fileExists(atPath: provisionUrl.path),
					FileManager.default.fileExists(atPath: passwordUrl.path)
				else {
					Logger.misc.warning("Skipping \(certName): missing required files")
					continue
				}
				
				let password = try String(contentsOf: passwordUrl, encoding: .utf8)
				
				Zenith.handleCertificateFiles(
					p12URL: p12Url,
					provisionURL: provisionUrl,
					p12Password: password,
					certificateName: certName,
					isDefault: true
				) { _ in
					
				}
			}
			UserDefaults.standard.set(true, forKey: "zenith.didImportDefaultCertificates")
		} catch {
			Logger.misc.error("Failed to list signing-assets: \(error)")
		}
	}

}
