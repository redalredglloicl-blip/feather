
//
//  ZenithSingleFileSigner.swift
//  Zenith
//
//  Phase 1 container — single-file signing route for JITLess
//  validation (Worker E).
//
//  Problem: LCUtils.signFilesWithZSignWithURLs (called only by
//  validateJITLessSetupWithCompletionHandler, which test-signs
//  a single TestJITLess.dylib and then runs checkCodeSignature
//  on it) needs to sign ONE Mach-O file. The base Zsign
//  package has no single-file API — Zsign.sign / SignFolder
//  only sign whole bundles — and LC's ZSigner signMachOPathArr
//  does not exist here (its port lives only in the Zsign
//  submodule working tree and never reaches the cloud build).
//
//  Solution — temp-bundle wrapper, no new crypto: each file is
//  wrapped in a throwaway .app bundle (minimal Info.plist, the
//  file itself as the bundle executable), signed with the host
//  certificate through the existing ZenithGuestSigner shim
//  (same whole-bundle SignFolder call the importer uses), and
//  the signed file is copied back over the original path. The
//  CMS signature lives inside the Mach-O, so the copy back
//  keeps it and checkCodeSignature still passes.
//
//  Unproven until the cloud build + phone test (stated
//  honestly): whether Zsign.sign accepts a .dylib as the bundle
//  executable — its node signer handles dylibs, but the main
//  executable is normally MH_EXECUTE. If the phone test shows
//  the wrapper failing on the dylib, the fix is a tiny
//  MH_EXECUTE stub executable as the bundle main node with the
//  dylib as a Frameworks member (signed as a bundle node).
//  Also: TestJITLess.dylib itself is NOT in the app bundle yet
//  (no TestJITLess target vendored), so validateJITLessSetup
//  still fails at its copy step until that file is added — the
//  route below is real, the test asset is the remaining gap.
//

import Foundation

@objc final class ZenithSingleFileSigner: NSObject {

	/// Signs every file in `urls` in place via the temp-bundle
	/// wrapper. Synchronous; returns false on the first failure.
	/// ObjC-visible so LCUtils.signFilesWithZSignWithURLs can
	/// delegate to it.
	@objc(signFilesWithURLs:)
	static func signFiles(urls: [URL]) -> Bool {
		for url in urls {
			guard _signOneFile(url) else {
				return false
			}
		}
		return true
	}

	private static func _signOneFile(_ url: URL) -> Bool {
		let fm = FileManager.default
		guard fm.fileExists(atPath: url.path) else {
			return false
		}
		let exeName = url.lastPathComponent
		let tmpApp = fm.temporaryDirectory
			.appendingPathComponent("ZenithSingleFileSign-\(UUID().uuidString).app")
		defer {
			try? fm.removeItem(at: tmpApp)
		}
		do {
			try fm.createDirectory(at: tmpApp, withIntermediateDirectories: true)
			try fm.copyItem(at: url, to: tmpApp.appendingPathComponent(exeName))
			// Minimal bundle: zsign requires BundleID, BundleVersion
			// and BundleExecutable (GetSignFolderInfo errors without
			// any of them). The identifier is a throwaway — the file
			// is never installed, only its signature is checked.
			let info: [String: Any] = [
				"CFBundleIdentifier": "com.zenith.app.singlefilesign",
				"CFBundleExecutable": exeName,
				"CFBundleName": exeName,
				"CFBundleVersion": "1",
				"CFBundleShortVersionString": "1.0",
				"CFBundlePackageType": "APPL",
			]
			guard (info as NSDictionary).write(
				to: tmpApp.appendingPathComponent("Info.plist"),
				atomically: true
			) else {
				return false
			}
		} catch {
			return false
		}
		// The shim's sign is synchronous: the completion fires on
		// this thread before it returns — except on early failure
		// (no certificate), where it returns false and never
		// calls the completion. Both must be checked.
		var signed = false
		let started = ZenithGuestSigner.signGuestApp(atPath: tmpApp.path) { signed = $0 }
		guard started, signed else {
			return false
		}
		do {
			try fm.removeItem(at: url)
			try fm.copyItem(at: tmpApp.appendingPathComponent(exeName), to: url)
			return true
		} catch {
			return false
		}
	}
}
