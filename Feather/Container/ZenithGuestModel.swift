//
//  ZenithGuestModel.swift
//  Zenith
//
//  Phase 1 container — guest model, adapted from LCAppInfo
//  (LiveContainer b0f53e89, LiveContainerSwiftUI/Models/LCAppInfo).
//
//  Deliberately a small subset: only what the Library launcher
//  and the importer need. NOT carried over: TweakLoader itself /
//  tweak folders, multitasking, keychain groups, web clips,
//  orientation lock, JIT flags, 32-bit / classic mode, shared
//  apps, hidden/locked flags. The two TweakLoader OFF flags
//  (dontInjectTweakLoader / dontLoadTweakLoader) ARE carried
//  over as plist keys — set YES at import so the launch-time
//  patcher never injects the loader. The guest record in Core
//  Data stays the existing `Imported` row — this model is the
//  on-disk sidecar (LCAppInfo.plist) beside the bundle, never
//  a second Core Data entity.
//
//  Revision note: LC tracks its Mach-O patch with
//  `LCPatchRevision` (rev 7 includes the dylib-load patch for
//  the tweak loader). Phase 1 does NOT patch a load command
//  (no TweakLoader — the injected dylib is what crashed the
//  game), so this model records our own `ZenithPatchRevision`
//  and leaves `LCPatchRevision` untouched: a later patch step
//  can still tell the LC patch never ran.
//

import Foundation

// MARK: - Guest info (LCAppInfo.plist sidecar)
final class ZenithGuestInfo {

	/// Our import-time patch revision. 1 = Phase 1: ARM64e slice
	/// fixup + signature-artifact strip + host-cert sign.
	static let currentPatchRevision = 1

	/// The guest .app bundle on disk.
	let bundleURL: URL

	/// Contents of LCAppInfo.plist (empty when the file is absent).
	private(set) var info: [String: Any]

	/// Contents of the bundle's own Info.plist.
	private(set) var infoPlist: [String: Any]

	init(bundleURL: URL) {
		self.bundleURL = bundleURL
		self.info = (NSDictionary(contentsOf: bundleURL.appendingPathComponent("LCAppInfo.plist")) as? [String: Any]) ?? [:]
		self.infoPlist = (NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")) as? [String: Any]) ?? [:]
	}

	// MARK: Identity (from Info.plist)

	var displayName: String? {
		(infoPlist["CFBundleDisplayName"] as? String)
			?? (infoPlist["CFBundleName"] as? String)
			?? (infoPlist["CFBundleExecutable"] as? String)
	}

	var bundleIdentifier: String? {
		infoPlist["CFBundleIdentifier"] as? String
	}

	var version: String? {
		(infoPlist["CFBundleShortVersionString"] as? String)
			?? (infoPlist["CFBundleVersion"] as? String)
	}

	// MARK: Container state (from LCAppInfo.plist)

	/// Per-guest data-container id. Written at import; the
	/// launcher stores it as `selectedContainer`.
	var dataUUID: String? {
		info["LCDataUUID"] as? String
	}

	/// Bundle identifier the guest had before import. The
	/// Library record keeps this identifier; the guest's
	/// Info.plist is never rewritten to the host bundle id.
	var originalBundleIdentifier: String? {
		info["LCOriginalBundleIdentifier"] as? String
	}

	var patchRevision: Int {
		info["ZenithPatchRevision"] as? Int ?? 0
	}

	var installationDate: Date? {
		info["installationDate"] as? Date
	}

	var lastLaunched: Date? {
		info["lastLaunched"] as? Date
	}

	/// Names of staged dylibs copied into Frameworks/ at import
	/// (never load-command-injected in Phase 1 — see
	/// StagedPatchApplier.stageDylibs). Kept so the later
	/// in-process loader knows what is staged.
	var stagedDylibs: [String] {
		info["ZenithStagedDylibs"] as? [String] ?? []
	}

	/// Phase 1 container, TweakLoader flags (LCAppInfo keys,
	/// same names the LC patcher reads at launch).
	///
	/// Both are YES for every guest imported by Zenith, set
	/// HERE at import — before the LC patcher ever runs:
	/// - `dontInjectTweakLoader` defaults NO in LC, so an
	///   unset flag makes the launch-time patcher inject a
	///   REAL LC_LOAD_DYLIB for
	///   @loader_path/../../Tweaks/TweakLoader.dylib — a file
	///   that does not exist in Phase 1, so dyld would refuse
	///   to load the guest. With YES the patcher instead
	///   writes the placeholder load command (cmd 0x114514,
	///   path /usr/lib/libc++.1.dylib — LCMachOUtils.m:199/204)
	///   which dyld skips, and LC's own scanner skips it too
	///   (:149). TweakLoader.dylib itself is NOT required.
	/// - `dontLoadTweakLoader` tells the bootstrap not to load
	///   the tweak loader at launch either.
	/// PHASE 1 CORRECTION: the patcher runs via
	/// LCAppInfo.patchExecAndSignIfNeed at import
	/// (ZenithGuestImporter._patchExecAndSign) — not only at
	/// launch — so the flags above are already in place when
	/// the patch step writes the placeholder load command
	/// (cmd 0x114514, path /usr/lib/libc++.1.dylib —
	/// LCMachOUtils.m:199/204) instead of a real
	/// LC_LOAD_DYLIB for the TweakLoader dylib.
	/// The flags still matter at launch because LCBootstrap
	/// reads them straight from the LCAppInfo.plist dict:
	/// dontInject=YES skips the (already false) inject path,
	/// and dontInject=YES + dontLoad=YES skips the TweakLoader
	/// dlopen (LCBootstrap.m:650/683). The LC setter for
	/// dontInjectTweakLoader also forces LCPatchRevision=-1
	/// (re-patch); writing the flag into a fresh sidecar at
	/// import has the same effect, because the sidecar
	/// carries no LCPatchRevision yet and the first
	/// launch-time patch runs with the flags in place.
	var dontInjectTweakLoader: Bool {
		info["dontInjectTweakLoader"] as? Bool ?? false
	}

	var dontLoadTweakLoader: Bool {
		info["dontLoadTweakLoader"] as? Bool ?? false
	}

	/// Records a launch (called by the launcher before relaunch).
	func recordLaunched() {
		info["lastLaunched"] = Date()
		save()
	}

	/// Persists LCAppInfo.plist beside the bundle.
	func save() {
		(info as NSDictionary).write(
			to: bundleURL.appendingPathComponent("LCAppInfo.plist"),
			atomically: true
		)
	}

	/// Builds the sidecar for a freshly imported guest and
	/// writes it into the bundle.
	@discardableResult
	static func create(
		bundleURL: URL,
		originalBundleIdentifier: String,
		dataUUID: String,
		stagedDylibs: [String] = []
	) -> ZenithGuestInfo {
		let guest = ZenithGuestInfo(bundleURL: bundleURL)
		guest.info["LCDataUUID"] = dataUUID
		guest.info["LCOriginalBundleIdentifier"] = originalBundleIdentifier
		guest.info["ZenithPatchRevision"] = currentPatchRevision
		guest.info["installationDate"] = Date()
		// Phase 1: NEVER inject the tweak loader (see the
		// dontInjectTweakLoader doc above). Set at import so
		// the first launch-time patch already sees them.
		guest.info["dontInjectTweakLoader"] = true
		guest.info["dontLoadTweakLoader"] = true
		if !stagedDylibs.isEmpty {
			guest.info["ZenithStagedDylibs"] = stagedDylibs
		}
		guest.save()
		return guest
	}
}
