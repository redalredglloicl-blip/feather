//
//  ZenithGuestImporter.swift
//  Zenith
//
//  Phase 1 container — import flow.
//
//  Chain (LiveContainer model, Zenith parts):
//    IPA / extracted .app
//      → copy to a temp work dir (the Library copy is never
//        patched in place, so a failed import leaves it intact)
//      → StagedPatchApplier: display name / version + every
//        staged file-based mod patch (same appliers the old
//        signing flow used — one source of truth)
//      → strip _CodeSignature / embedded.mobileprovision +
//        ARM64e slice fixup (already-bridged Mach-O helper)
//      → stage dylibs into Frameworks/ WITHOUT a load command
//        (no TweakLoader in Phase 1 — the injected dylib is
//        what crashed the game before)
//      → move to Documents/Applications/<bundle-id>.app +
//        LCAppInfo.plist sidecar
//      → PATCH + SIGN in one upstream call:
//        LCAppInfo.patchExecAndSignIfNeed (Mach-O executable
//        → dylib, then sign with the host certificate)
//      → verify the signature + record the Library link.
//
//  PATCH + SIGN — READ THIS BEFORE CHANGING IT. The import
//  does NOT sign on its own: it calls the upstream
//  LCAppInfo.patchExecAndSignIfNeed (ObjC
//  patchExecAndSignIfNeedWithCompletionHandler:progressHandler:
//  forceSign:, LCAppInfo.m:296; Swift name as used by
//  LCAppModel.signApp), which does the patch AND the sign in
//  one call. That is the whole Blocker B fix: before this,
//  the only caller of the patch step was the excluded
//  LCAppModel, so the import signed an UNPATCHED MH_EXECUTE
//  guest and the launch-time dlopen could never succeed.
//  The call (forceSign: false — a fresh guest carries no
//  LCPatchRevision yet, so the patch always runs and the
//  patch itself forces the sign):
//    1. Patch, when LCPatchRevision < 7: copy-delete-move
//       the executable (avoids the codesigning SIGKILL),
//       then per ARM64 slice LCPatchExecSlice — MH_EXECUTE
//       → MH_DYLIB, __PAGEZERO shrunk, LC_ID_DYLIB inserted,
//       and the load command written as the placeholder
//       (cmd 0x114514, /usr/lib/libc++.1.dylib) because the
//       sidecar sets dontInjectTweakLoader=YES — no
//       TweakLoader in Phase 1, and no real load command is
//       ever added. Then the ARM64e slice fixup, the
//       app-extension patch, LCPatchRevision=7, save.
//    2. Skip the sign, reporting SUCCESS, when there is no
//       stored cert password, the guest is 32-bit, or
//       dontSign is set — so the password MUST be mirrored
//       first (LCZenithCertificate.mirrorPasswordForLaunch,
//       called right before the patch call below).
//    3. Skip the sign when the signature is already valid
//       (unless forced).
//    4. Otherwise sign via LCUtils.signAppBundleWithZSign →
//       the ZenithGuestSigner shim → base Zsign.sign
//       (ZBundle.SignFolder), then re-verify with
//       checkCodeSignature and report failure when the
//       signature is not valid. A separate ZsignHandler
//       sign step would sign the bundle TWICE — there is
//       none, on purpose.
//  The ported LC ZSigner (+signWithAppPath:bundleId:cert:
//  pass:) is NOT called here: the sign above goes through
//  the shim instead, which reads the host cert from the
//  LCZenithCertificate adapter (on-disk p12 + provision
//  paths, password). Verified from the submodule source:
//  zsign() is SYNCHRONOUS (completion fires before it
//  returns), and it passes EMPTY dylib lists — signing never
//  injects anything.
//
//  HOST BUNDLE ID — deliberate deviation, source-verified:
//  LC signs with the host bundle id, but in zsign's API the
//  bundle-id parameter REWRITES the guest's Info.plist
//  CFBundleIdentifier (ZBundle.ModifyBundleInfo) — it does
//  NOT change the cryptographic identity, which comes from
//  the provision (team id + provision entitlements). Passing
//  com.zenith.app would rewrite every guest to one shared
//  bundle id, breaking the Library record link and colliding
//  every guest's data container. So customIdentifier stays
//  EMPTY: the guest keeps its original bundle id (in
//  Info.plist and in the CodeDirectory ident), and its
//  signature still carries the HOST cert's team id (from
//  the p12). CORRECTION (verified in bundle.cpp): with
//  removeProvision=true the guest ends up with NO
//  embedded.mobileprovision — SignFolder writes the host
//  provision (:683) and then deletes it again while building
//  CodeResources (:184), excluding it from the signature.
//  The log line "Exclude MobileProvision: NO" (:737) is
//  upstream zsign's own mislabel — trust the code, not the
//  log. Whether the provision's entitlements still land in
//  the binary's __entitlements section was not verified in
//  source; the phone test is the proof. If the phone test
//  ever shows iOS rejecting the guest at load because the
//  ident is not the host id, the fix is one line (pass the
//  host id) PLUS a Library-linkage fix for the rewritten
//  id — do not apply it blindly.
//
//  This IS LC's patch + sign flow now, not a parallel one —
//  the only deliberate deviation left is the bundle id
//  (above). The guest's own original entitlements (keychain
//  groups, app groups) are NOT merged in Phase 1: the guest
//  runs inside Zenith's process, under Zenith's entitlements.
//

import Foundation
import OSLog
import Zsign

// MARK: - Import result / stages
enum ZenithGuestImporter {

	struct Result {
		let guest: ZenithGuestInfo
		/// .deb files staged for injection that were skipped
		/// (Phase 1 stages .dylib only — see stageDylibs).
		let skippedDebCount: Int
	}

	enum Stage {
		case copying
		case patching
		case signing
		case finishing

		var progress: Double {
			switch self {
			case .copying: return 0.1
			case .patching: return 0.4
			case .signing: return 0.75
			case .finishing: return 1.0
			}
		}

		var statusKey: String {
			switch self {
			case .copying: return "جارٍ نسخ الملفات..."
			case .patching: return "جارٍ تطبيق التعديلات..."
			case .signing: return "جارٍ التوقيع..."
			case .finishing: return "جارٍ الاستيراد..."
			}
		}
	}

	enum ImportError: Error, LocalizedError {
		case updateRequired
		case checkFailed
		case noCertificate
		case alreadyGuest
		case appNotFound
		case generic

		var errorDescription: String? {
			switch self {
			case .updateRequired:
				return ForcedUpdateError.updateRequired.localizedDescription
			case .checkFailed:
				return ForcedUpdateError.checkFailed.localizedDescription
			case .noCertificate:
				return .localized("ما عندك شهادة — استورد شهادة من الإعدادات أولاً.")
			case .alreadyGuest, .appNotFound, .generic:
				return .localized("صار خطأ أثناء الاستيراد — حاول مرة ثانية.")
			}
		}
	}

	// MARK: - Entry points

	/// Converts an already-imported Library app (any app: its
	/// extracted .app lives at Documents/Unsigned/<uuid>/)
	/// into a guest. The Library record is untouched.
	/// NOTE (additive-only re-scope): v2.13 readers do NOT
	/// resolve the record to the guest bundle afterwards —
	/// Storage.getAppDirectory still returns the Unsigned
	/// path, which is KEPT on success (proof decision), so
	/// icon / file size / info keep working for guest rows.
	/// Guest lookup lives only in ZenithGuestStore. Fully
	/// generic: nothing here knows or cares which app is
	/// being imported.
	static func importGuest(
		from app: AppInfoPresentable,
		options: Options,
		progress: @escaping (Double, Stage) -> Void
	) async throws -> Result {
		guard let sourceAppDir = Storage.shared.getAppDirectory(for: app) else {
			throw ImportError.appNotFound
		}
		guard !ZenithGuestStore.isGuest(app) else {
			throw ImportError.alreadyGuest
		}
		let uuid = app.uuid ?? UUID().uuidString
		let result = try await _run(
			sourceAppDir: sourceAppDir,
			dataUUID: uuid,
			originalName: app.name,
			originalVersion: app.version,
			options: options,
			progress: progress
		)
		// The old Unsigned copy STAYS (proof decision): keeping
		// it preserves every v2.13 display — Library icon,
		// file size, info rows, and re-sign via the restored
		// Sign button, which all still resolve through
		// Storage.getAppDirectory to the Unsigned path — at
		// the cost of double disk use per guest (one copy in
		// Unsigned/<uuid>/, one in Applications/<id>.app).
		// Acceptable for the proof; a later version can delete
		// the copy once v2.13 readers resolve guest rows.
		await _notifyImported(uuid: uuid)
		return result
	}

	/// Imports a fresh IPA file straight to a guest: extract
	/// to temp, convert, then create the Library entry.
	static func importGuest(
		fromIPA ipaURL: URL,
		options: Options,
		progress: @escaping (Double, Stage) -> Void
	) async throws -> Result {
		let uuid = UUID().uuidString
		let handler = AppFileHandler(file: ipaURL)
		try await handler.copy()
		do {
			try await handler.extract()
		} catch {
			try? await handler.clean()
			throw error
		}
		guard
			let payload = handler.uniqueWorkDirPayload,
			let payloadApp = FileManager.default.getPath(in: payload, for: "app")
		else {
			try? await handler.clean()
			throw ImportError.appNotFound
		}
		guard
			let bundle = Bundle(url: payloadApp),
			let identifier = bundle.bundleIdentifier,
			!ZenithGuestStore.isBundleIdentifierGuest(identifier)
		else {
			try? await handler.clean()
			throw ImportError.alreadyGuest
		}
		do {
			let result = try await _run(
				sourceAppDir: payloadApp,
				dataUUID: uuid,
				originalName: bundle.name,
				originalVersion: bundle.version,
				options: options,
				progress: progress
			)
			try? await handler.clean()
			Storage.shared.addImported(
				uuid: uuid,
				source: nil,
				appName: bundle.name,
				appIdentifier: bundle.bundleIdentifier,
				appVersion: bundle.version,
				appIcon: bundle.iconFileName
			) { _ in }
			await _notifyImported(uuid: uuid)
			return result
		} catch {
			try? await handler.clean()
			throw error
		}
	}

	// MARK: - Core pipeline

	private static func _run(
		sourceAppDir: URL,
		dataUUID: String,
		originalName: String?,
		originalVersion: String?,
		options: Options,
		progress: @escaping (Double, Stage) -> Void
	) async throws -> Result {
		// Forced-update gate FIRST, same as the old signing
		// entry point (Zenith.signPackageFile): an import must
		// never be a way around the update check.
		guard await ForcedUpdateManager.shared.ensureSignAllowed() else {
			if await ForcedUpdateManager.shared.isUpdateRequired {
				throw ImportError.updateRequired
			} else {
				throw ImportError.checkFailed
			}
		}

		// Host certificate up front: fail fast before any file
		// work when there is nothing to sign with. The p12 is
		// a FILE on disk — the file-path signing API reads it
		// in place (no temp copy of the bytes). The provision
		// is deliberately NOT required here: the shim passes
		// "" when the cert has no provision file, and signing
		// proceeds — a p12-only certificate must still import.
		guard
			LCZenithCertificate.selectedCertificate != nil,
			LCZenithCertificate.certificateData != nil,
			LCZenithCertificate.p12Path != nil
		else {
			throw ImportError.noCertificate
		}

		let fileManager = FileManager.default
		let workDir = fileManager.temporaryDirectory
			.appendingPathComponent("ZenithGuestImport_\(dataUUID)", isDirectory: true)
		try fileManager.createDirectoryIfNeeded(at: workDir)
		let workAppDir = workDir.appendingPathComponent(sourceAppDir.lastPathComponent)

		await _report(progress, .copying)
		do {
			try fileManager.copyItem(at: sourceAppDir, to: workAppDir)
		} catch {
			try? fileManager.removeItem(at: workDir)
			throw error
		}

		// Bundle identifier: the folder name and the sidecar
		// both key off it, and the Library record keeps it.
		guard
			let infoPlist = NSDictionary(contentsOf: workAppDir.appendingPathComponent("Info.plist")) as? [String: Any],
			let bundleIdentifier = infoPlist["CFBundleIdentifier"] as? String,
			!bundleIdentifier.isEmpty
		else {
			try? fileManager.removeItem(at: workDir)
			throw ImportError.appNotFound
		}

		// Best-effort backup of the untouched original, same
		// call the old signing flow makes (gated inside the
		// manager on the backup toggle). Never blocks import.
		_ = await BackupManager.shared.backupAppDirectory(
			workAppDir,
			appName: originalName,
			appVersion: originalVersion
		)

		await _report(progress, .patching)
		let skippedDebs: Int
		do {
			// Display name / version first (same order as the
			// old flow: identity into Info.plist, then patches).
			try StagedPatchApplier.applyIdentity(options: options, to: workAppDir)
			try StagedPatchApplier.applyModPatches(options: options, to: workAppDir)
			try StagedPatchApplier.stripSignatureArtifacts(in: workAppDir)
			StagedPatchApplier.fixupARM64eSlices(in: workAppDir)
			let staged = try StagedPatchApplier.stageDylibs(options.injectionFiles, to: workAppDir)
			skippedDebs = staged.skippedDebs

			// Sidecar beside the bundle, before the move.
			_ = ZenithGuestInfo.create(
				bundleURL: workAppDir,
				originalBundleIdentifier: bundleIdentifier,
				dataUUID: dataUUID,
				stagedDylibs: staged.staged
			)
		} catch {
			try? fileManager.removeItem(at: workDir)
			throw error
		}

		// Move to its final home, then sign IN PLACE (the old
		// flow signs the moved copy too — same call shape).
		let folderName = ZenithGuestStore.uniqueFolderName(forBundleIdentifier: bundleIdentifier)
		let guestBundleURL = ZenithGuestStore.applicationsDirectory.appendingPathComponent(folderName)
		do {
			try fileManager.createDirectoryIfNeeded(at: ZenithGuestStore.applicationsDirectory)
			try fileManager.moveItem(at: workAppDir, to: guestBundleURL)
			try? fileManager.removeItem(at: workDir)
		} catch {
			try? fileManager.removeItem(at: workDir)
			throw error
		}

		await _report(progress, .signing)
		do {
			// Mirror the selected cert's password into the LC
			// stores BEFORE patching: the patch step's sign
			// branch SKIPS signing (and still reports success)
			// when no password is stored, and the launch-time
			// re-sign path reads it from there too.
			LCZenithCertificate.mirrorPasswordForLaunch()
			// Upstream patch + sign in one call (see the header
			// note): LCAppInfo.patchExecAndSignIfNeed patches
			// the Mach-O executable into a dylib (MH_EXECUTE
			// → MH_DYLIB, placeholder load command — no
			// TweakLoader in Phase 1) and then signs with the
			// host certificate through the same shim the old
			// step used (LCUtils.signAppBundleWithZSign →
			// ZenithGuestSigner → Zsign.sign, empty custom
			// identifier, no embedded provision). No separate
			// sign step: signing with ZsignHandler as well
			// would sign the bundle twice.
			try await _patchExecAndSign(guestBundleURL: guestBundleURL, progress: progress)
			// Honest post-sign check: the signature must at
			// least be well-formed before the import is
			// reported as done.
			guard
				let execPath = Bundle(url: guestBundleURL)?.executableURL?.path,
				Zsign.checkSigned(appExecutable: execPath)
			else {
				throw ImportError.generic
			}
		} catch {
			try? fileManager.removeItem(at: guestBundleURL)
			throw error
		}

		// Guest data dir (empty for now — the loader owns it).
		try? fileManager.createDirectoryIfNeeded(at: ZenithGuestStore.dataDirectory(for: dataUUID))

		await _report(progress, .finishing)
		Logger.misc.info("[ZenithGuestImporter] Imported guest \(bundleIdentifier) → \(guestBundleURL.lastPathComponent)")
		return Result(
			guest: ZenithGuestInfo(bundleURL: guestBundleURL),
			skippedDebCount: skippedDebs
		)
	}

	// MARK: - Helpers

	private static func _report(
		_ progress: @escaping (Double, Stage) -> Void,
		_ stage: Stage
	) async {
		await MainActor.run {
			progress(stage.progress, stage)
		}
	}

	/// Upstream-faithful wrapper around
	/// LCAppInfo.patchExecAndSignIfNeed (ObjC
	/// patchExecAndSignIfNeedWithCompletionHandler:
	/// progressHandler:forceSign:, LCAppInfo.m:296 — the Swift
	/// name is the one LCAppModel.signApp uses).
	/// forceSign is false: a freshly imported guest carries
	/// no LCPatchRevision yet, so the patch always runs, and
	/// the patch itself forces the sign. The completion
	/// reports (success, errorInfo); a failure throws
	/// ImportError.generic and the upstream message is logged
	/// (the user-facing string stays the generic Iraqi one).
	/// The sign NSProgress fraction is forwarded into the
	/// .signing stage, the same shape as LCAppModel; the
	/// observation is held in a box the completion closure
	/// retains, so it lives until the patch call answers.
	private static func _patchExecAndSign(
		guestBundleURL: URL,
		progress: @escaping (Double, Stage) -> Void
	) async throws {
		guard let appInfo = LCAppInfo(bundlePath: guestBundleURL.path) else {
			Logger.misc.error("[ZenithGuestImporter] LCAppInfo(bundlePath:) returned nil for \(guestBundleURL.path, privacy: .public)")
			throw ImportError.generic
		}
		final class ProgressBox {
			var observation: NSKeyValueObservation?
		}
		let box = ProgressBox()
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			appInfo.patchExecAndSignIfNeed(completionHandler: { success, errorInfo in
				box.observation?.invalidate()
				box.observation = nil
				if success {
					continuation.resume()
				} else {
					let message = errorInfo ?? "unknown error"
					Logger.misc.error("[ZenithGuestImporter] patch/sign failed: \(message, privacy: .public)")
					continuation.resume(throwing: ImportError.generic)
				}
			}, progressHandler: { signProgress in
				guard let signProgress else { return }
				box.observation = signProgress.observe(\.fractionCompleted) { progressObject, _ in
					DispatchQueue.main.async {
						progress(
							Stage.signing.progress + (Stage.finishing.progress - Stage.signing.progress) * progressObject.fractionCompleted,
							.signing
						)
					}
				}
			}, forceSign: false)
		}
	}

	private static func _notifyImported(uuid: String) async {
		await MainActor.run {
			NotificationCenter.default.post(
				name: ZenithGuestStore.didImportGuestNotification,
				object: nil,
				userInfo: ["uuid": uuid]
			)
		}
	}
}
