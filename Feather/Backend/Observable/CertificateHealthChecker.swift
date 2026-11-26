//
//  CertificateHealthChecker.swift
//  Feather
//
//  Zenith v2.2: certificate health check. It runs the real OCSP check
//  that already exists in Zsign (`Zsign.checkRevokage` → `checkCert`
//  in zsign.mm): the cert's OCSP responder is asked whether Apple
//  revoked this certificate, and the responder's own answer decides.
//
//  The result is reported HONESTLY — nothing is faked:
//  - `.healthy` only when the OCSP responder answers GOOD (status 0).
//  - `.revoked` only when the responder answers REVOKED (status 1).
//  - `.unverified` for everything else (status 2): no network, the
//    responder errored, the cert has no OCSP URL, or the issuer is
//    not one of the two Apple Developer CAs `checkCert` recognises.
//    That last case matters: a shared enterprise certificate whose
//    issuer hash is not in that hardcoded list can NEVER return a
//    positive answer from this check, so it shows "could not verify"
//    — never a fake healthy badge. The responder's own error text
//    is kept in `reason` so the UI can show why.
//
//  Note: OCSP needs a live connection to Apple's responder. In Iraq
//  Apple services are blocked without a VPN, so an unverified result
//  with a network error is expected there — it means "unknown", not
//  "revoked".
//

import Foundation
import Zsign

// MARK: - Result
enum CertificateHealth: Equatable {
	/// No check has run yet.
	case unknown
	/// A check is running.
	case checking
	/// The OCSP responder answered GOOD for this certificate.
	case healthy
	/// The OCSP responder answered REVOKED for this certificate.
	case revoked
	/// The check could not run or gave no verdict. `reason` is the
	/// real error text from the check, when one was reported.
	case unverified(reason: String?)
}

// MARK: - Checker
final class CertificateHealthChecker: ObservableObject {
	@Published private(set) var status: CertificateHealth = .unknown
	@Published private(set) var lastChecked: Date?

	private var _isChecking = false

	/// Runs the OCSP revocation check for this certificate. While a
	/// check is running, further calls are ignored.
	func check(cert: CertificatePair) {
		guard !_isChecking else {
			return
		}
		guard
			let provisionURL = Storage.shared.getFile(.provision, from: cert),
			let p12URL = Storage.shared.getFile(.certificate, from: cert)
		else {
			_setStatus(.unverified(reason: .localized("ملفات الشهادة مو موجودة")))
			return
		}

		_isChecking = true
		_setStatus(.checking)

		Zsign.checkRevokage(
			provisionPath: provisionURL.path,
			p12Path: p12URL.path,
			p12Password: cert.password ?? ""
		) { [weak self] status, _, error in
			// checkCert's completion arrives on a URLSession thread.
			DispatchQueue.main.async {
				guard let self else {
					return
				}
				self._isChecking = false
				self.lastChecked = Date()
				switch status {
				case 0:
					// V_OCSP_CERTSTATUS_GOOD
					self._setStatus(.healthy)
				case 1:
					// V_OCSP_CERTSTATUS_REVOKED — mirror the stored
					// flag the Library already reads.
					cert.revoked = true
					Storage.shared.saveContext()
					self._setStatus(.revoked)
				default:
					// V_OCSP_CERTSTATUS_UNKNOWN and every error path
					// in checkCert report 2: no verdict, not a pass.
					self._setStatus(.unverified(reason: error))
				}
			}
		}
	}

	private func _setStatus(_ status: CertificateHealth) {
		// Called from the main thread only (check's entry point runs
		// on the main actor via the view; the OCSP completion hops
		// to the main queue above).
		if Thread.isMainThread {
			self.status = status
		} else {
			DispatchQueue.main.async { self.status = status }
		}
	}
}
