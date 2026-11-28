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
	/// v2.38: true when the launch check could not reach any
	/// decision within the bounded wait and there is no cached
	/// decision to open on. The entry screen then shows a plain
	/// error with a retry button instead of trying forever.
	@Published private(set) var checkFailed = false

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
		// v2.38: ONE bounded wait, no retry counter. The old code
		// re-spawned the check forever and showed the live attempt
		// count in the label ("Checking for updates — retry N",
		// climbing without end when the fresh check never completes
		// and no cache exists) — the "محاولة" loop Reda reported.
		// Now the label stays plain "Checking for updates" while
		// waiting, the wait stops at ~12 s no matter what, and a
		// launch with no decision at all shows a plain error with
		// a retry button instead of trying forever (see
		// _waitForLaunchDecision and retryCheck). A cached block
		// still shows instantly (the root branch shows
		// ForcedUpdateView above this screen).
		//
		// v2.40: cached-first — the stall Reda reported (the screen
		// parking at 75% for seconds) was this step waiting out the
		// whole ~30 s deadline even when a cached "fine" existed:
		// a cached decision never set hasLaunchDecision, and the
		// fresh fetch effectively never completes on his phone, so
		// every launch sat at 75% until the deadline. Now a cached
		// "fine" opens at once and the fresh check refreshes in the
		// background; a later fresh check that blocks still flips
		// the UI to the update screen the moment it answers. Only
		// a launch with NO cached decision at all still waits (now
		// ~12 s, one short retry round) and then shows the error +
		// retry button. The only exits without any decision are
		// cancellation and a genuinely offline device — in the
		// offline case the root branch shows OfflineBlockView
		// instead, so the app is never bricked by the wait.
		_setStep(0.75, .localized("Checking for updates"))
		guard await _waitForLaunchDecision() else {
			checkFailed = true
			return
		}
		await _settle()
		guard !Task.isCancelled else { return }

		await _finishStartup()
	}

	/// Retries the launch check after a failed wait (checkFailed):
	/// one more bounded wait for a launch decision, then the same
	/// finish as a normal launch. User-initiated only — one tap is
	/// one bounded attempt, never an automatic loop, and no attempt
	/// count is ever shown.
	func retryCheck() async {
		guard !isFinished, !_isRunning else { return }
		_isRunning = true
		defer { _isRunning = false }
		checkFailed = false
		guard await _waitForLaunchDecision() else {
			checkFailed = true
			return
		}
		await _settle()
		guard !Task.isCancelled else { return }
		await _finishStartup()
	}

	/// Waits for the forced-update launch decision, bounded to ~12 s.
	/// Returns true when the launch may proceed: a cached "fine"
	/// (v2.40: opens at once, fresh check refreshes in the
	/// background), a cached block, or a fresh decision. Returns
	/// false when the deadline passed with no decision at all — the
	/// caller shows the plain error + retry button instead of
	/// waiting forever. While waiting the label stays plain
	/// "Checking for updates": no attempt count is ever shown.
	/// Rounds already retry inside the manager
	/// (ForcedUpdateManager), so re-spawning a round here only
	/// happens while enough time remains in the same ~12 s window.
	private func _waitForLaunchDecision() async -> Bool {
		let manager = ForcedUpdateManager.shared
		// v2.40 cached-first: a cached block is already a decision —
		// the root branch shows ForcedUpdateView above this screen,
		// so finishing the launch here can never open past it.
		if manager.isUpdateRequired {
			return true
		}
		// v2.40 cached-first: a cached "fine" opens at once instead
		// of parking at 75% until the deadline. The fresh check
		// still runs, in the background: it joins the launch check
		// the app root already started, and a fresh decision that
		// blocks flips the UI to the update screen the moment it
		// answers (the manager's published isUpdateRequired).
		// hasPassedCheck stays false — only a fresh check passes —
		// but signing follows the cached decision itself, as before.
		if manager.cachedDecisionAllowsSigning {
			Task { await ForcedUpdateManager.shared.checkForUpdate() }
			manager.applyCachedFallbackForLaunch()
			return true
		}
		let deadline = Date().addingTimeInterval(12)
		_checkDone = false
		_checkTask = Task { [weak self] in
			await ForcedUpdateManager.shared.checkForUpdate()
			self?._checkDone = true
		}
		while !ForcedUpdateManager.shared.hasLaunchDecision, !Task.isCancelled {
			if NetworkMonitor.shared.isOffline {
				return false
			}
			// Deadline: no fresh decision in ~12 s — stop waiting
			// either way (v2.38: no endless retry loop). The code
			// after the loop opens on the cached decision when
			// there is one, or reports failure.
			if Date() > deadline {
				break
			}
			if _checkDone {
				// The round ended without a fresh decision (the
				// fetches kept failing while the device still
				// reports online): run it again after a short
				// pause, but only while enough time remains for
				// another short round — otherwise the deadline
				// above ends the wait instead of spawning a round
				// that cannot finish.
				if Date().addingTimeInterval(6) > deadline {
					break
				}
				_checkDone = false
				try? await Task.sleep(nanoseconds: 1_000_000_000)
				if Task.isCancelled || NetworkMonitor.shared.isOffline {
					return false
				}
				if Date() > deadline {
					break
				}
				_checkTask = Task { [weak self] in
					await ForcedUpdateManager.shared.checkForUpdate()
					self?._checkDone = true
				}
			}
			try? await Task.sleep(nanoseconds: 200_000_000)
		}
		if ForcedUpdateManager.shared.hasLaunchDecision {
			return true
		}
		// Deadline: no fresh decision in ~12 s — open on the
		// cached decision instead of hanging forever.
		if ForcedUpdateManager.shared.hasAnyCachedValue {
			ForcedUpdateManager.shared.applyCachedFallbackForLaunch()
			return true
		}
		return false
	}

	/// Step 5 + finish, shared by run() and retryCheck(): the fixed
	/// theme, then the "Ready" mark that lets the app open.
	private func _finishStartup() async {
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

				if _progress.checkFailed {
					// v2.38: the launch check could not reach any
					// decision in ~12 s and there is no cached
					// decision to open on — a plain error and a
					// retry button, never an endless retry count.
					// Same peach button as the forced-update
					// screen; nothing else on this screen changes.
					Text(verbatim: ForcedUpdateError.checkFailed.localizedDescription)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.padding(.top, 14)
						.padding(.horizontal, 32)

					Button {
						Task { await _progress.retryCheck() }
					} label: {
						Text(.localized("حاول مرة ثانية"))
							.font(.headline)
							.frame(maxWidth: .infinity)
							.padding()
							.background(Color(hex: "#FFC778"))
							.foregroundStyle(.black)
							.clipShape(RoundedRectangle(cornerRadius: 14))
					}
					.padding(.horizontal, 32)
					.padding(.top, 16)
					.padding(.bottom, 56)
				} else {
					Text(verbatim: _progress.stepLabel)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.padding(.top, 14)
						.padding(.bottom, 56)
				}
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
