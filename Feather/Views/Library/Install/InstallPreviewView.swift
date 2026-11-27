//
//  InstallPreview.swift
//  Zenith
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("Zenith.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@AppStorage("Zenith.installationMethod") private var _installationMethod: Int = 0
	@State private var _isWebviewPresenting = false
	// Zenith v2.16: guards for the direct itms-services open —
	// open once per install attempt, and the 15s honest-stall
	// watchdog (see _openInstallLinkExternal).
	@State private var _didOpenInstallLink = false
	@State private var _stallWatchdog: Task<Void, Never>?
	@State private var progressTask: Task<Void, Never>?
	
	var app: AppInfoPresentable
	@StateObject var viewModel: InstallerStatusViewModel
	@StateObject var installer: ServerInstaller
	
	@State var isSharing: Bool
	
	init(app: AppInfoPresentable, isSharing: Bool = false) {
		self.app = app
		self.isSharing = isSharing
		let viewModel = InstallerStatusViewModel(isIdevice: UserDefaults.standard.integer(forKey: "Zenith.installationMethod") == 1)
		self._viewModel = StateObject(wrappedValue: viewModel)
		self._installer = StateObject(wrappedValue: try! ServerInstaller(app: app, viewModel: viewModel))
	}
	
	// MARK: Body
	var body: some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		ZStack {
			InstallProgressView(app: app, viewModel: viewModel)
			_status()
			_button()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.zenithGlassCard(cornerRadius: cornerRadius, fallback: Color(UIColor.secondarySystemBackground))
		.padding()
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.onReceive(viewModel.$status) { newStatus in
			if _installationMethod == 0 {
				if case .ready = newStatus {
					// Zenith v2.15: ask the installer which server method
					// is actually in effect — getServerMethod() falls
					// back to Semi Local (1) when the "Fully Local" TLS
					// pack is missing or expired, so this view must not
					// trust its own stored default here, or it would
					// open an http manifest URL iOS refuses.
					if installer.getServerMethod() == 0 {
						_openInstallLink()
					} else {
						// Zenith v2.16: NO Safari sheet. Mode 1 used to
						// open the local server page, whose HTML
						// redirected to the itms-services link — iOS
						// then asked the confusing "Open this page
						// in 'iTunes'?" question, Reda pressed back,
						// and the install sat on "Ready" forever with
						// no icon and no error. The itms-services
						// link (palera.in manifest) opens directly
						// now, with the same refused-link handling
						// as mode 0. The sheet stays in the code,
						// dormant.
						_openInstallLinkExternal()
					}
				}
				
				if case .sendingPayload = newStatus {
					// The install really started: iOS is fetching
					// the IPA from the local server — the stall
					// watchdog has nothing to do.
					_stallWatchdog?.cancel()
					_stallWatchdog = nil
				}
				
				if case .installing = newStatus {
					_stallWatchdog?.cancel()
					_stallWatchdog = nil
					if progressTask == nil {
						progressTask = startInstallProgressPolling(
							bundleID: app.identifier!,
							viewModel: viewModel
						)
					}
				}
				
				switch newStatus {
				case .completed, .broken(_):
					if case .completed = newStatus {
						LibraryPrefs.shared.recordOpened(uuid: app.uuid)
					}
					progressTask?.cancel()
					progressTask = nil
					_stallWatchdog?.cancel()
					_stallWatchdog = nil
					_didOpenInstallLink = false
					#if !targetEnvironment(macCatalyst)
					BackgroundAudioManager.shared.stop()
					#endif
				default:
					break
				}
			}
		}
		.onAppear(perform: _install)
		
		#if !targetEnvironment(macCatalyst)
		.onAppear {
			BackgroundAudioManager.shared.start()
		}
		#endif
		
		.onDisappear {
			progressTask?.cancel()
			progressTask = nil
			_stallWatchdog?.cancel()
			_stallWatchdog = nil
			
			#if !targetEnvironment(macCatalyst)
			BackgroundAudioManager.shared.stop()
			#endif
		}
	}
	
	@ViewBuilder
	private func _status() -> some View {
		Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
			.padding()
			.labelStyle(.titleAndIcon)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
			.animation(.smooth, value: viewModel.statusImage)
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if viewModel.isCompleted {
				Button {
					LibraryPrefs.shared.recordOpened(uuid: app.uuid)
					UIApplication.openApp(with: app.identifier ?? "")
				} label: {
					NBButton("Open", systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}
	
	// Zenith v2.15: the old code force-unwrapped the itms-services URL
	// and ignored open()'s result, so when iOS refused the link (dead
	// TLS pack, unresolvable host) the sheet sat at "Ready" forever
	// with no prompt and no error. A refused link now fails honestly:
	// status becomes Error and the user is told, instead of hanging.
	private func _openInstallLink() {
		guard let itunesURL = URL(string: installer.iTunesLink) else {
			viewModel.status = .broken(InstallLinkError.invalidLink)
			return
		}
		
		UIApplication.shared.open(itunesURL, options: [:]) { opened in
			guard opened else {
				DispatchQueue.main.async {
					viewModel.status = .broken(InstallLinkError.systemRefused)
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: "ما گدرت أفتح رابط التثبيت. جرّب طريقة التثبيت الثانية من الإعدادات.",
						action: {
							dismiss()
						}
					)
				}
				return
			}
		}
	}
	
	// Zenith v2.16: mode 1 ("Semi Local") direct open. The
	// itms-services link carries the palera.in manifest URL
	// (installer.iTunesLinkExternal — verified good), opened
	// straight with UIApplication.shared.open instead of going
	// through the Safari sheet's "Open this page in 'iTunes'?"
	// detour. Same refused-link handling as mode 0.
	private func _openInstallLinkExternal() {
		// onReceive can fire twice for one .ready status —
		// opening itms-services twice would show two install
		// prompts. Open once per install attempt.
		guard !_didOpenInstallLink else { return }
		_didOpenInstallLink = true
		
		guard let itunesURL = URL(string: installer.iTunesLinkExternal) else {
			viewModel.status = .broken(InstallLinkError.invalidLink)
			return
		}
		
		UIApplication.shared.open(itunesURL, options: [:]) { opened in
			DispatchQueue.main.async {
				guard opened else {
					viewModel.status = .broken(InstallLinkError.systemRefused)
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: "ما گدرت أفتح رابط التثبيت. جرّب طريقة التثبيت الثانية من الإعدادات.",
						action: {
							dismiss()
						}
					)
					return
				}
				_startStallWatchdog()
			}
		}
	}
	
	// Zenith v2.16 honest stall: the link opened, but if iOS
	// never fetches the IPA from the local server
	// (.sendingPayload) and never starts installing within 15
	// seconds, the install never started — say so plainly
	// instead of sitting on "جاهز" forever. Cancelled as soon
	// as real progress arrives (.sendingPayload / .installing /
	// terminal status) or the view disappears.
	private func _startStallWatchdog() {
		_stallWatchdog?.cancel()
		_stallWatchdog = Task.detached {
			try? await Task.sleep(nanoseconds: 15_000_000_000)
			guard !Task.isCancelled else { return }
			await MainActor.run {
				if case .ready = viewModel.status {
					viewModel.status = .broken(InstallLinkError.installNeverStarted)
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: "التثبيت ما بدأ — ما وصل شي للشاشة. جرّب تثبيت مرة ثانية.",
						action: {
							dismiss()
						}
					)
				}
			}
		}
	}
	
	private func _install() {
		guard isSharing || app.identifier != Bundle.main.bundleIdentifier! || _installationMethod == 1 else {
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}
				
		Task.detached {
			// Zenith forced update: installing refuses unless the
			// launch decision allows it — a fresh check passed, or
			// a cached decision says this build is fine (v2.13).
			// A known block still refuses.
			guard await ForcedUpdateManager.shared.ensureSignAllowed() else {
				await MainActor.run {
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: ForcedUpdateManager.shared.isUpdateRequired
							? .localized("حدّث Zenith أولاً.")
							: .localized("ما قدرت أتأكد من إصدار التطبيق. تأكد من النت وحاول مرة ثانية.")
					)
				}
				return
			}
			do {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				
				let packageUrl = try await handler.archive()
				
				if await !isSharing {
					if await _installationMethod == 0 {
						await MainActor.run {
							installer.packageUrl = packageUrl
							viewModel.status = .ready
						}
						
						if case .installing = await viewModel.status {
							let task = await startInstallProgressPolling(
								bundleID: app.identifier!,
								viewModel: viewModel
							)

							await MainActor.run {
								progressTask = task
							}
						}
					} else if await _installationMethod == 1 {
						let handler = await InstallationProxy(viewModel: viewModel)
						try await handler.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier!)
					}
				} else {
					let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)
					
					if await !_useShareSheet {
						await MainActor.run {
							dismiss()
						}
					} else {
						if let package {
							await MainActor.run {
								dismiss()
								UIActivityViewController.show(activityItems: [package])
							}
						}
					}
				}
			} catch {
				await progressTask?.cancel()
				
				await MainActor.run {
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: String(describing: error),
						action: {
							HeartbeatManager.shared.start(true)
							dismiss()
						}
					)
				}
			}
		}
	}
	
	private func startInstallProgressPolling(
		bundleID: String,
		viewModel: InstallerStatusViewModel
	) -> Task<Void, Never> {

		Task.detached(priority: .background) {
			var hasStarted = false

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = await hasStarted
					? _normalizeInstallProgress(rawProgress)
					: 0.0

				Logger.misc.info("Install progress for \(bundleID): \(progress)")

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
			}
		}
	}

	private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
}

// Zenith v2.15: errors for a refused itms-services link (see
// _openInstallLink). No new xcstrings key: the messages are plain
// literals, shown only in the install-failure alert path.
private enum InstallLinkError: LocalizedError {
	case invalidLink
	case systemRefused
	// Zenith v2.16: the itms-services link opened, but iOS never
	// fetched the IPA and never started installing within 15s.
	case installNeverStarted
	
	var errorDescription: String? {
		switch self {
		case .invalidLink: "رابط التثبيت مو صحيح."
		case .systemRefused: "النظام رفض رابط التثبيت."
		case .installNeverStarted: "التثبيت ما بدأ. جرّب مرة ثانية."
		}
	}
}
