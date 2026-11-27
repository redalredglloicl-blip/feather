//
//  ZenithGuestLauncher.swift
//  Zenith
//
//  Phase 1 container — launch. Swift equivalent of LC's
//  launchToGuestAppWithURL: (LiveContainer b0f53e89,
//  LiveContainer/LCSharedUtils.m).
//
//  LC's contract, kept exactly so the guest-entry side can be
//  LC-shaped: write the selected guest folder name to
//  `selected` and its data-container id to
//  `selectedContainer` (both in UserDefaults.standard — the
//  same keys LC reads), then ask the workspace to open Zenith
//  itself and kill this process, so iOS relaunches the app
//  fresh and the launch branch enters the guest.
//
//  What this file does NOT do: the launch branch that READS
//  `selected` / `selectedContainer` on startup and loads the
//  guest binary is main.c + LCBootstrap.m (LiveContainerMain),
//  which consume both keys before jumping to the guest.
//  Until that branch exists in the build, a launch writes the
//  selection and relaunches into Zenith normally; the selection
//  stays on disk, so the guest still opens on the next manual
//  relaunch once the entry branch exists.
//

import Darwin
import Foundation
import UIKit

// MARK: - Guest launcher
enum ZenithGuestLauncher {

	/// UserDefaults keys, identical to LC's. Do not rename:
	/// the guest-entry side reads these exact keys.
	static let selectedKey = "selected"
	static let selectedContainerKey = "selectedContainer"

	/// The folder name of the currently selected guest, if a
	/// launch was requested and not yet consumed.
	static var selectedGuestFolderName: String? {
		UserDefaults.standard.string(forKey: selectedKey)
	}

	/// The data-container id of the currently selected guest.
	static var selectedGuestContainer: String? {
		UserDefaults.standard.string(forKey: selectedContainerKey)
	}

	/// Clears a consumed (or stale) selection. The launch
	/// branch calls this after reading the keys.
	static func clearSelection() {
		UserDefaults.standard.removeObject(forKey: selectedKey)
		UserDefaults.standard.removeObject(forKey: selectedContainerKey)
	}

	/// Launches a guest inside Zenith: writes the selection,
	/// records the open, asks the workspace to reopen Zenith,
	/// then kills this process so iOS starts it fresh.
	/// Returns false (and does NOT kill anything) when the
	/// app has no guest bundle on disk — the caller shows an
	/// honest error instead.
	///
	/// The relaunch side exists now: main.c (entry point)
	/// reads `selected` and, when a guest is selected and the
	/// gates pass, dlopens LiveContainerShared and jumps to
	/// LiveContainerMain (LCBootstrap.m), which consumes the
	/// keys and runs the guest in-process. A normal launch
	/// (no `selected`) never touches that path — main.c calls
	/// main() directly.
	@discardableResult
	static func launch(_ app: AppInfoPresentable) -> Bool {
		guard
			let guest = ZenithGuestStore.guestInfo(for: app),
			let dataUUID = guest.dataUUID,
			FileManager.default.fileExists(atPath: guest.bundleURL.path)
		else {
			return false
		}

		let folderName = guest.bundleURL.lastPathComponent
		// Mirror the selected cert's password into the LC
		// stores NOW: the bootstrap reads it right after
		// the relaunch below, and this is the last code
		// that runs before the SIGKILL — the synchronize()
		// after the selection writes flushes it to disk
		// together with the selection.
		LCZenithCertificate.mirrorPasswordForLaunch()
		UserDefaults.standard.set(folderName, forKey: selectedKey)
		UserDefaults.standard.set(dataUUID, forKey: selectedContainerKey)
		// The process is about to be killed: force the
		// selection to disk NOW. A SIGKILL right after a
		// plain set could otherwise lose the write (the
		// values live in memory until the prefs daemon
		// flushes them). Deprecated but still honored.
		UserDefaults.standard.synchronize()

		LibraryPrefs.shared.recordOpened(uuid: app.uuid)
		guest.recordLaunched()

		// Reopen ourselves through the same private workspace
		// call the launch flow already uses
		// (NimbleKit UIApplication.openApp), then die so iOS
		// starts us fresh into the guest — LC's shape
		// (open + SIGKILL in the completion). The delay gives
		// the workspace request time to register; if it never
		// does, the selection above still stands, so a manual
		// re-tap enters the guest once the entry branch lands.
		if let ownBundleID = Bundle.main.bundleIdentifier {
			UIApplication.openApp(with: ownBundleID)
		}
		DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
			raise(SIGKILL)
		}
		return true
	}
}
