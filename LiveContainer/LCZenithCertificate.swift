//
//  LCZenithCertificate.swift
//  Zenith
//
//  Phase 1 container — certificate adapter (Worker B spec).
//
//  The guest importer signs with the HOST certificate, read
//  directly from Zenith's own storage — no app-group mirror:
//  the main app's entitlements contain only get-task-allow, so
//  an LC-style shared-defaults mirror (LCCertificateData /
//  LCCertificatePassword) would silently fail. The p12 lives as
//  a FILE at Documents/Certificates/<uuid>/<file>.p12 (via
//  Storage.getFile), the password is the plaintext
//  CertificatePair.password, and the selected certificate is the
//  "zenith.selectedCert" index (fallback: first certificate).
//  The existing file-path signing API (ZsignHandler / Zsign.sign)
//  takes p12 + provision PATHS, so no temp-file copy of the cert
//  bytes is needed — the p12 file is read in place.
//

import Foundation

// MARK: - Host certificate (single source for the guest importer)
enum LCZenithCertificate {

	/// The certificate the guest is signed with: the
	/// "zenith.selectedCert" index into the date-sorted list,
	/// falling back to the first certificate. Same lookup the
	/// signing screen uses (SigningView._selectedCert).
	static var selectedCertificate: CertificatePair? {
		let certs = Storage.shared.getAllCertificates()
		guard !certs.isEmpty else { return nil }
		let index = UserDefaults.standard.integer(forKey: "zenith.selectedCert")
		if certs.indices.contains(index) {
			return certs[index]
		}
		return certs.first
	}

	/// Raw p12 bytes of the selected certificate, or nil when
	/// there is no selected certificate or its file is gone.
	/// Exposed for callers that need bytes; the file-path
	/// signing API reads the same file via `p12Path` instead.
	static var certificateData: Data? {
		guard
			let cert = selectedCertificate,
			let url = Storage.shared.getFile(.certificate, from: cert)
		else {
			return nil
		}
		return try? Data(contentsOf: url)
	}

	/// Password for the selected certificate's p12.
	static var certificatePassword: String? {
		selectedCertificate?.password ?? ""
	}

	/// On-disk p12 path for the file-path signing API.
	static var p12Path: String? {
		guard
			let cert = selectedCertificate,
			let url = Storage.shared.getFile(.certificate, from: cert)
		else {
			return nil
		}
		return url.path
	}

	/// On-disk .mobileprovision path for the file-path signing API.
	static var provisionPath: String? {
		guard
			let cert = selectedCertificate,
			let url = Storage.shared.getFile(.provision, from: cert)
		else {
			return nil
		}
		return url.path
	}

	/// Mirrors the SELECTED certificate's password into the LC
	/// password stores, via [LCUtils setCertificatePassword:]
	/// (declared in LCUtils.h, implemented in LCUtils.m).
	/// That method writes key `LCCertificatePassword` to BOTH
	/// standard defaults and the LC app-group suite; the suite
	/// write silently does nothing (no app-group entitlement
	/// in Phase 1) and the standard-defaults write is the one
	/// that matters in-process — LCSharedUtils
	/// .certificatePassword reads the suite first, then
	/// standard defaults. Without this mirror the bootstrap
	/// (LCBootstrap.invokeAppMain → JITLess) sees no password
	/// and demands JIT, so no guest launches on a
	/// non-debugger phone. Called ONLY from new proof code:
	/// right before a guest import signs (ZenithGuestImporter)
	/// and right before a launch relaunches
	/// (ZenithGuestLauncher) — the launch call is the
	/// guarantee, because it runs immediately before the
	/// bootstrap reads the password. Mirrors even an EMPTY
	/// password: LC's patch step treats a nil
	/// LCCertificatePassword as "no certificate configured"
	/// and silently SKIPS signing while reporting success — then
	/// the importer's post-sign check fails the import with the
	/// generic error. An empty string is a real value (a
	/// password-less p12, like the shared enterprise cert); it
	/// passes LC's nil check, and Zsign opens the p12 with it
	/// exactly like the old signing flow (ZsignHandler passes
	/// cert.password ?? "" with no isEmpty guard). Does nothing
	/// when there is no selected certificate.
	static func mirrorPasswordForLaunch() {
		guard selectedCertificate != nil else {
			return
		}
		LCUtils.setCertificatePassword(certificatePassword ?? "")
	}
}
