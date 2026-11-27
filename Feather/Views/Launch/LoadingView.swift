//
//  LoadingView.swift
//  Zenith
//
//  Zenith v2.3 startup screen: black starfield, the Zenith planet and a
//  1→100 counter. The counter is driven ONLY by real startup steps —
//  storage load, certificate load, expiry reminders, the forced-update
//  check and the fixed theme — never a fake timer. Each step sets the
//  next progress target; the number animates up to it while the step
//  actually runs. A short settle pause per step keeps the counter
//  readable when a step finishes instantly.
//
//  Wiring (ZenithApp.swift): shown as the first screen while
//  `_startupDone` is false; the forced-update gate above it is
//  untouched, so a cached block still shows ForcedUpdateView first.
//  The steps below intentionally repeat idempotent startup work
//  (reminders, theme) that ZenithApp also runs on appear — running
//  them twice is harmless, and moving them here would drop other
//  agents' concurrent additions to that onAppear.

import SwiftUI
import CoreData
import UIKit

// MARK: - Startup progress (real steps only)
@MainActor
final class StartupProgress: ObservableObject {
	@Published private(set) var progress: Double = 0
	@Published private(set) var stepLabel: String = .localized("Loading apps")
	@Published private(set) var isFinished = false

	private var _isRunning = false
	private var _checkDone = false
	private var _checkTask: Task<Void, Never>?

	func run() async {
		guard !isFinished, !_isRunning else { return }
		_isRunning = true
		defer { _isRunning = false }

		// Step 1 — storage: count the stored apps. This warms the
		// Core Data stack the Library's fetch requests use next.
		_setStep(0.15, .localized("Loading apps"))
		let context = Storage.shared.context
		let signedCount = (try? context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Signed"))) ?? 0
		let importedCount = (try? context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Imported"))) ?? 0
		_ = signedCount + importedCount
		await _settle()
		guard !Task.isCancelled else { return }

		// Step 2 — certificates: the real Core Data fetch.
		_setStep(0.35, .localized("Loading certificates"))
		let certificates = Storage.shared.getAllCertificates()
		await _settle()
		guard !Task.isCancelled else { return }

		// Step 3 — expiry reminders + background refresh schedule.
		// requestAuthorization is safe to call repeatedly; reminders
		// for a certificate replace their own previous requests.
		_setStep(0.55, .localized("Setting up reminders"))
		NotificationManager.shared.requestAuthorization()
		certificates.forEach { NotificationManager.shared.scheduleExpiryReminders(for: $0) }
		AutoRefreshManager.shared.scheduleBackgroundRefresh()
		await _settle()
		guard !Task.isCancelled else { return }

		// Step 4 — forced-update check (real network). The manager
		// shares one in-flight check between callers, so this joins
		// the launch check instead of starting a second one.
		//
		// v2.11 waited here with NO deadline for a FRESH decision
		// (both minVersion and killed fetched live) — and build 13
		// hung at 75% across restarts, because the check never
		// completes fresh on this phone. v2.12 bounds the wait: at
		// most ~30 s for a fresh decision; if none arrives and the
		// cache can decide, the launch opens on the cached decision
		// (see ForcedUpdateManager.applyCachedFallbackForLaunch).
		// With no cached value at all there is nothing to open on,
		// so the step keeps waiting — but the label below shows the
		// live attempt count, so a retrying launch never looks frozen
		// at 75%. A cached block still shows instantly (the root
		// branch shows ForcedUpdateView above this screen), and a
		// later fresh check that blocks flips the UI the moment it
		// answers. The only exits without any decision are
		// cancellation and a genuinely offline device — in the
		// offline case the root branch shows OfflineBlockView
		// instead, so the app is never bricked by the wait.
		_setStep(0.75, .localized("Checking for updates"))
		let step4Deadline = Date().addingTimeInterval(30)
		_checkTask = Task { [weak self] in
			await ForcedUpdateManager.shared.checkForUpdate()
			self?._checkDone = true
		}
		var lastShownAttempt = 0
		while !ForcedUpdateManager.shared.hasLaunchDecision, !Task.isCancelled {
			if NetworkMonitor.shared.isOffline {
				return
			}
			if _checkDone {
				// The round ended without a fresh decision (the fetches
				// kept failing while the device still reports online):
				// run it again after a short pause.
				_checkDone = false
				try? await Task.sleep(nanoseconds: 2_000_000_000)
				if Task.isCancelled || NetworkMonitor.shared.isOffline {
					return
				}
				_checkTask = Task { [weak self] in
					await ForcedUpdateManager.shared.checkForUpdate()
					self?._checkDone = true
				}
			}
			// Deadline: no fresh decision in ~30 s — open on the
			// cached decision instead of hanging forever.
			if Date() > step4Deadline, ForcedUpdateManager.shared.hasAnyCachedValue {
				ForcedUpdateManager.shared.applyCachedFallbackForLaunch()
				break
			}
			// Live retrying state: the % stays at 75 (this step is
			// genuinely not done) — the label is what moves, showing
			// the real attempt count, so the screen never looks frozen.
			let attempts = ForcedUpdateManager.shared.checkAttempts
			if attempts > 1, attempts != lastShownAttempt {
				lastShownAttempt = attempts
				_setRetryingLabel(attempts)
			}
			try? await Task.sleep(nanoseconds: 200_000_000)
		}
		await _settle()
		guard !Task.isCancelled else { return }

		// Step 5 — fixed theme: dark mode + peach accent, no choice.
		_setStep(0.9, .localized("Almost done"))
		UIApplication.topViewController()?.view.window?.overrideUserInterfaceStyle = .dark
		UIApplication.topViewController()?.view.window?.tintColor = UIColor(Color(hex: "#FFC778"))
		UserDefaults.standard.removeObject(forKey: "Zenith.userInterfaceStyle")
		UserDefaults.standard.removeObject(forKey: "Zenith.shouldTintIcons")
		UserDefaults.standard.removeObject(forKey: "Zenith.shouldChangeIconsBasedOffStyle")
		UserDefaults.standard.set("#FFC778", forKey: "Zenith.userTintColor")
		await _settle()
		guard !Task.isCancelled else { return }

		_setStep(1.0, .localized("Ready"))
		await _settle()
		isFinished = true
	}

	private func _setStep(_ target: Double, _ label: String) {
		withAnimation(.easeInOut(duration: 0.45)) {
			progress = target
			stepLabel = label
		}
	}

	/// Shows the live retry count while step 4 waits for a fresh
	/// decision. Label only — the progress value stays at 0.75
	/// because the step genuinely has not finished.
	private func _setRetryingLabel(_ attempt: Int) {
		stepLabel = .localized("Checking for updates — retry %lld", arguments: attempt)
	}

	/// Brief pause so the counter is readable even when a step
	/// finishes instantly. The VALUE still comes from the steps.
	private func _settle() async {
		try? await Task.sleep(nanoseconds: 250_000_000)
	}
}

// MARK: - View
struct LoadingView: View {
	var onFinished: () -> Void

	@StateObject private var _progress = StartupProgress()

	var body: some View {
		ZStack {
			VStack(spacing: 0) {
				Spacer()

				// Zenith v2.3 launch look (mockup): the realistic planet
				// big and centred, then huge thin peach numerals and a
				// thin glowing line. No wordmark — the planet is the mark.
				Image("zenith-transparent")
					.resizable()
					.scaledToFit()
					.frame(width: 270, height: 270)

				Spacer()

				HStack(alignment: .lastTextBaseline, spacing: 2) {
					Text("\(Int(_progress.progress * 100))")
						.font(.system(size: 68, weight: .thin))
						.monospacedDigit()
						.foregroundStyle(Color(hex: "#FFC778"))
					Text("%")
						.font(.system(size: 30, weight: .light))
						.foregroundStyle(Color(hex: "#FFC778"))
				}

				GeometryReader { geo in
					ZStack(alignment: .leading) {
						Capsule()
							.fill(Color.white.opacity(0.15))
						Capsule()
							.fill(Color(hex: "#FFC778"))
							.frame(width: max(0, geo.size.width * CGFloat(_progress.progress)))
							.shadow(color: Color(hex: "#FFC778").opacity(0.8), radius: 6, x: 0, y: 0)
					}
				}
				.frame(height: 3)
				.padding(.horizontal, 64)
				.padding(.top, 16)

				Text(verbatim: _progress.stepLabel)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.padding(.top, 14)
					.padding(.bottom, 56)
			}
		}
		.starfieldBackground()
		.task {
			await _progress.run()
		}
		.onChange(of: _progress.isFinished) { finished in
			if finished {
				onFinished()
			}
		}
	}
}
