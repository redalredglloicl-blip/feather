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
	// Zenith v2.23: honest stall note while installd fetches the
	// IPA — a 45s timer started on .sendingPayload; if the status
	// is still .sendingPayload when it fires, the note shows.
	@State private var _payloadStallTask: Task<Void, Never>?
	@State private var _showPayloadStallNote = false
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
		// Zenith v2.20: the install sheet used to be swipe-dismissable
		// mid-download — dismissing it deallocated the local server
		// (its only owner is this view) and installd was left with a
		// half-fetched IPA and a white placeholder icon forever.
		// While an install is in flight the sheet cannot be swiped
		// away; once the install reaches a terminal status
		// (.completed / .broken) dismissing is allowed again.
		.interactiveDismissDisabled(_isInstallInFlight)
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.onReceive(viewModel.$status) { newStatus in
			// Zenith v2.23: the payload-stall note. Start the 45s
			// timer on .sendingPayload; any other status clears
			// the timer and the note.
			if case .sendingPayload = newStatus {
				_startPayloadStallTimer()
			} else {
				_payloadStallTask?.cancel()
				_payloadStallTask = nil
				_showPayloadStallNote = false
			}
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
					// Zenith v2.20: stop the background-audio keep-alive
					// ONLY on a completed install. On .broken the local
					// server must stay alive — installd may still be
					// fetching the IPA, and stopping the audio lets iOS
					// suspend Zenith and kill the server mid-download,
					// leaving a white placeholder icon on the home
					// screen forever. The audio stops on real dismissal
					// (onDisappear) instead.
					if case .completed = newStatus {
						#if !targetEnvironment(macCatalyst)
						BackgroundAudioManager.shared.stop()
						#endif
					}
				default:
					break
				}
			}
		}
		.onAppear(perform: _install)
		
		#if !targetEnvironment(macCatalyst)
		.onAppear {
			BackgroundAudioManager.shared.start()
			// Zenith v2.21: keep the install server (and the
			// process) alive outside this sheet — see
			// InstallSessionManager. The sheet's own audio hold
			// below is not enough: its onDisappear fires on any
			// teardown of the sheet, which deallocates the server
			// mid-download. The session's hold survives that.
			// Share flows (isSharing) need no server: archiving
			// only produces a file, so no session is begun there.
			if !isSharing {
				InstallSessionManager.shared.begin(server: installer, viewModel: viewModel)
			}
		}
		#endif
		
		.onDisappear {
			progressTask?.cancel()
			progressTask = nil
			_stallWatchdog?.cancel()
			_stallWatchdog = nil
			_payloadStallTask?.cancel()
			_payloadStallTask = nil
			_showPayloadStallNote = false
			
			#if !targetEnvironment(macCatalyst)
			BackgroundAudioManager.shared.stop()
			#endif
		}
	}
	
	// Zenith v2.20: true while installd may still need the local
	// server — the sheet must not be swipe-dismissed in that window
	// (see .interactiveDismissDisabled above). Terminal statuses
	// allow dismissing again.
	private var _isInstallInFlight: Bool {
		switch viewModel.status {
		case .ready, .sendingManifest, .sendingPayload, .installing:
			return true
		default:
			return false
		}
	}
	
	@ViewBuilder
	private func _status() -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
			// Zenith v2.24: show the real failure behind a bare
			// "خطأ" — the attached .broken error's description
			// (see statusDetail), so the next failed install says
			// WHY instead of ending on a bare warning triangle.
			if let detail = viewModel.statusDetail {
				Text(detail)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			if _showPayloadStallNote {
				Text("التحميل واقف — السيرفر توقف. جرّب إلغاء وإعادة التثبيت.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}
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
	
	// Zenith v2.20 honest stall: the link opened, but if iOS
	// never fetches the IPA from the local server
	// (.sendingPayload) and never starts installing within 60
	// seconds, the install never started — say so plainly
	// instead of sitting on "جاهز" forever. 60s, not 15s: the
	// clock includes palera's manifest fetch plus the time Reda
	// takes to read and confirm the system Install prompt, and
	// 15s fired while he was merely being slow — then it stopped
	// the background audio and dismissed the sheet, killing the
	// server just as installd was about to fetch. The alert no
	// longer dismisses the sheet: the server stays alive and he
	// can swipe away and retry when he is ready. Cancelled as
	// soon as real progress arrives (.sendingPayload / .installing
	// / terminal status) or the view disappears.
	private func _startStallWatchdog() {
		_stallWatchdog?.cancel()
		_stallWatchdog = Task.detached {
			try? await Task.sleep(nanoseconds: 60_000_000_000)
			guard !Task.isCancelled else { return }
			await MainActor.run {
				if case .ready = viewModel.status {
					viewModel.status = .broken(InstallLinkError.installNeverStarted)
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: "التثبيت ما بدأ — ما وصل شي للشاشة. جرّب تثبيت مرة ثانية."
					)
				}
			}
		}
	}
	
	// Zenith v2.23: honest payload-stall note. installd is
	// fetching the IPA from the local server; if the status is
	// still .sendingPayload 45s later the fetch has stalled
	// (most likely the server died while Zenith was
	// backgrounded) — say so under the status line instead of
	// sitting on the progress text forever. Cancelled as soon as
	// the status leaves .sendingPayload or the view disappears.
	private func _startPayloadStallTimer() {
		_payloadStallTask?.cancel()
		_showPayloadStallNote = false
		_payloadStallTask = Task.detached {
			try? await Task.sleep(nanoseconds: 45_000_000_000)
			guard !Task.isCancelled else { return }
			await MainActor.run {
				if case .sendingPayload = viewModel.status {
					_showPayloadStallNote = true
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
					// Zenith v2.21: archiving failed — nothing to
					// serve, so release the install session (server
					// + keep-alive) now instead of holding it for
					// the grace period.
					InstallSessionManager.shared.end()
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
			// Zenith v2.20: the progress object disappearing used to
			// mean "installed" — but it also disappears when installd
			// gives up, which falsely reported success while the
			// home-screen icon stayed a white placeholder. Now a
			// disappearance only counts when the bundle is really
			// installed; otherwise we wait a short grace period and
			// then fail honestly instead of claiming success.
			var missingTicks = 0
			// Zenith v2.25: the highest progress ever seen, so the
			// failure verdict can say which stage it died on — a
			// verdict after real progress means installd gave up at
			// verification, not during the download.
			var peakProgress = 0.0

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
					missingTicks = 0
				}

				let progress = await hasStarted
					? _normalizeInstallProgress(rawProgress)
					: 0.0

				peakProgress = max(peakProgress, progress)

				Logger.misc.info("Install progress for \(bundleID): \(progress)")

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					let installed = UIApplication.isAppInstalled(bundleID)
					// installed == nil: the system could not answer
					// (unknown iOS) — keep the old behaviour rather
					// than failing an install that may have worked.
					if installed == true || installed == nil {
						await MainActor.run {
							viewModel.installProgress = 1.0
							viewModel.status = .completed(.success(()))
						}
						break
					}
					missingTicks += 1
					if missingTicks >= 10 {
						await MainActor.run {
							viewModel.status = .broken(InstallLinkError.installDidNotFinish(
								lastStatus: viewModel.statusLabel,
								peakProgress: peakProgress
							))
						}
						break
					}
				}

				try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s
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
	// Zenith v2.20: the install progress object vanished after the
	// install had started, but the bundle is not installed —
	// installd gave up. Reported honestly instead of claiming
	// success (the old code set .completed here, which is how
	// Zenith said "done" while the home-screen icon stayed a white
	// placeholder).
	// Zenith v2.25: carries the last status and the highest
	// progress seen, so the verdict names the stage it died on
	// instead of the bare "try again" — the poll only starts once
	// the payload stream has finished, so any verdict here means
	// the download completed and installd gave up at verification.
	case installDidNotFinish(lastStatus: String, peakProgress: Double)
	
	var errorDescription: String? {
		switch self {
		case .invalidLink: "رابط التثبيت مو صحيح."
		case .systemRefused: "النظام رفض رابط التثبيت."
		case .installNeverStarted: "التثبيت ما بدأ. جرّب مرة ثانية."
		case .installDidNotFinish(let lastStatus, let peakProgress): "التثبيت ما اكتمل — التطبيق ما انثبّت. آخر حالة: \(lastStatus)، وأعلى تقدّم وصل \(Int(peakProgress * 100))%. جرّب مرة ثانية."
		}
	}
}
