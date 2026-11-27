//
//  ZenithGuestSigner.swift
//  Zenith
//
//  ObjC-callable bridge from LCUtils (LiveContainer guest signing) to the
//  already-linked base Zsign package AND to the LCZenithCertificate adapter.
//  LCUtils.m (ObjC) cannot call either directly: Zsign.sign is a Swift enum
//  with no @objc exposure, and LCZenithCertificate is a Swift caseless enum.
//  This file is the only place that translates between the two.
//
//  Cert material comes from LCZenithCertificate (Zenith's own storage — the
//  selected certificate's on-disk p12 + provision paths and password). No
//  temp-file copy of the p12 is needed: the file-path signing API reads the
//  p12 file in place.
//
//  No ZSigner, no dylib: the ported ZSigner lives only in the Zsign
//  submodule working tree (uncommitted port) and never reaches the cloud
//  build. Everything here calls the base Zsign API
//  (khcrysalis/Zsign-Package @ c4ba9da4) that Zenith already links for
//  import signing. Fully generic: nothing here knows or cares which guest
//  is being signed — any .app bundle path works.
//

import Foundation
import Zsign

@objc final class ZenithGuestSigner: NSObject {
	/// Raw p12 bytes of the selected host certificate, via the
	/// LCZenithCertificate adapter. Nil when there is no selected
	/// certificate. ObjC-visible so LCUtils.certificateData can consult the
	/// adapter first (the LC shared-defaults mirror is not populated).
	@objc(guestCertificateData)
	static func guestCertificateData() -> Data? {
		LCZenithCertificate.certificateData
	}

	/// Signs a guest .app bundle with the host certificate, exactly the way
	/// import signing does — whole-bundle SignFolder via Zsign.sign.
	/// The p12 path, provision path and password are read from the
	/// LCZenithCertificate adapter inside this method; the caller only
	/// passes the guest bundle path.
	/// - customIdentifier is left empty on purpose: a non-empty value makes
	///   Zsign REWRITE the bundle's CFBundleIdentifier (bundle.cpp
	///   ModifyBundleInfo), which would rename the guest to the host ID and
	///   break LiveContainer's guest identity (selected / LCAppInfo.plist /
	///   container lookup all key on the guest's own bundle ID). Empty keeps
	///   the guest's own ID from its Info.plist as the signature identifier.
	/// - The host provision (when the selected cert has one) is passed so
	///   Zsign can derive the signing identity/entitlements from it, but
	///   removeProvision stays true: the guest's stale embedded
	///   .mobileprovision is stripped and none is embedded, matching LC's
	///   ZSigner flow (which embedded no provision). Guests run dlopen'd
	///   inside Zenith, never launched by SpringBoard, so no provision file
	///   is needed in the bundle. When the selected cert has no provision
	///   file, "" is passed instead.
	/// - No dylib is injected: disinject() / injectDyLib are never called.
	/// - Returns the synchronous Zsign.sign result; the completion closure
	///   fires on the calling thread when the synchronous sign finishes (or
	///   not at all on early failure, including "no certificate" — the
	///   caller must treat a false return as failure and never wait on the
	///   completion alone).
	@objc(signGuestAppAtPath:completion:)
	static func signGuestApp(
		atPath appPath: String,
		completion: @escaping (Bool) -> Void
	) -> Bool {
		// No isEmpty guard on the password on purpose: a
		// password-less p12 (empty string) is valid — Zsign
		// opens it with "", exactly like the old signing flow
		// (ZsignHandler passes cert.password ?? ""). Refusing
		// an empty password here made every guest import fail
		// with the generic error for a cert that signs fine.
		guard
			let p12Path = LCZenithCertificate.p12Path,
			let password = LCZenithCertificate.certificatePassword
		else {
			return false
		}
		return Zsign.sign(
			appPath: appPath,
			provisionPath: LCZenithCertificate.provisionPath ?? "",
			p12Path: p12Path,
			p12Password: password,
			entitlementsPath: "",
			removeProvision: true,
			completion: completion
		)
	}

	/// Certificate check backing LCUtils.validateCertificateWithCompletionHandler.
	/// Maps Zsign.checkRevokage (status, expirationDate, error) onto LC's
	/// (status, expirationDate, organizationalUnitName, error); the base API
	/// has no organisational-unit output, so that field is always nil.
	/// Answers asynchronously (OCSP network round-trip). When there is no
	/// selected certificate it answers (-6, nil, nil, "No certificate is
	/// available.") instead of doing nothing.
	@objc(checkGuestCertificateWithCompletionHandler:)
	static func checkGuestCertificate(
		completionHandler: @escaping (Int32, Date?, String?, String?) -> Void
	) {
		guard
			let p12Path = LCZenithCertificate.p12Path,
			let password = LCZenithCertificate.certificatePassword,
			!password.isEmpty
		else {
			completionHandler(-6, nil, nil, "No certificate is available.")
			return
		}
		Zsign.checkRevokage(
			provisionPath: LCZenithCertificate.provisionPath ?? "",
			p12Path: p12Path,
			p12Password: password
		) { status, expirationDate, error in
			completionHandler(status, expirationDate, nil, error)
		}
	}
}
