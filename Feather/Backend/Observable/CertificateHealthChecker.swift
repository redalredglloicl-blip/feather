//
//  CertificateHealthChecker.swift
//  Zenith
//
//  Zenith v2.3: certificate health is decided LOCALLY first, from the
//  certificate files themselves — never from the network.
//
//  Why: the old check was OCSP-only (`Zsign.checkRevokage`), and OCSP
//  can never answer healthy for Reda's certificate: Apple's OCSP
//  responder is unreachable/blocked in Iraq, and his shared
//  enterprise certificate's issuer is not in Zsign's hardcoded Apple
//  Developer CA list, so `checkCert` can never return GOOD for it.
//  The old UI therefore always showed "check the internet and try
//  again" — a network error dressed up as the verdict.
//
//  The new check, in order:
//  1. LOCAL (primary, decides the headline):
//     - the .p12 is parsed with SecPKCS12Import + swift-certificates (X509)
//       (expiry date, issuer, subject);
//     - the .mobileprovision is parsed directly (it is a plist/XML
//       file — the full Certificate decode first, a manual plist read
//       of ExpirationDate / TeamName / AppIDName as fallback);
//     - the stored Core Data expiry is a third source.
//     The effective expiry is the EARLIEST of the three. States:
//     healthy / expiring soon (< 30 days) / expired / invalid file
//     (a file exists but cannot be read — with the real reason).
//  2. OCSP (best-effort secondary, only when the local check passes):
//     it can only confirm the local verdict, or upgrade it to revoked
//     when the responder really answers REVOKED. When it is
//     unreachable or errors, the LOCAL verdict stays on screen with a
//     short note that the online check is unavailable. A network
//     failure is NEVER the headline, and "check the internet and try
//     again" is gone.
//  3. If no local data can be read at all, the state is "could not
//     verify" with the real reason — never a fake healthy, never a
//     fake error.
//

import Foundation
import Security
import X509
import SwiftASN1
import Zsign

// MARK: - Local details
/// Everything the local parse learned about a certificate. Shown in
/// the health card next to the verdict.
struct LocalCertificateDetails: Equatable {
	/// Expiry date from the .p12 (X509 DER parse).
	var p12Expiry: Date? = nil
	/// Subject summary from the .p12.
	var p12Subject: String? = nil
	/// Issuer (usually the common name) from the .p12.
	var p12Issuer: String? = nil
	/// The .p12 was there but could not be imported (wrong password,
	/// damaged file, ...). The verdict still stands on the profile.
	var p12Problem: String? = nil
	/// Expiry date from the .mobileprovision.
	var provisionExpiry: Date? = nil
	/// Team name from the .mobileprovision.
	var provisionTeamName: String? = nil
	/// App ID name from the .mobileprovision.
	var provisionAppIDName: String? = nil
	/// Earliest of p12 expiry, profile expiry, stored expiry.
	var effectiveExpiry: Date? = nil
	/// Whole days left until the effective expiry, never negative.
	var daysLeft: Int? = nil
}

// MARK: - Result
enum CertificateHealth: Equatable {
	/// No check has run yet.
	case unknown
	/// A check is running.
	case checking
	/// Local files say the certificate is valid. `onlineUnavailable`
	/// is true when the best-effort OCSP check could not run — the
	/// verdict is still the local one.
	case healthy(details: LocalCertificateDetails, onlineUnavailable: Bool)
	/// Local files say the certificate expires in under 30 days.
	case expiringSoon(details: LocalCertificateDetails, onlineUnavailable: Bool)
	/// Local files say the certificate already expired.
	case expired(details: LocalCertificateDetails)
	/// OCSP really answered REVOKED, or the certificate was already
	/// flagged revoked by an earlier OCSP answer.
	case revoked(details: LocalCertificateDetails?)
	/// A certificate file exists but cannot be read. `reason` is the
	/// real cause (wrong password, damaged file, ...).
	case invalid(reason: String)
	/// Nothing could be checked (files missing). `reason` is the real
	/// cause when one is known.
	case unverified(reason: String?)
}

// MARK: - Checker
final class CertificateHealthChecker: ObservableObject {
	@Published private(set) var status: CertificateHealth = .unknown
	@Published private(set) var lastChecked: Date?

	/// Days before expiry under which a certificate counts as
	/// expiring soon.
	static let expiringSoonThresholdDays = 30

	private var _isChecking = false
	/// Identifies the latest check run; a stale OCSP completion (from
	/// an earlier run) is ignored.
	private var _activeToken: UUID?

	/// Runs the local health check for this certificate. While a local
	/// check is running, further calls are ignored. The OCSP follow-up
	/// runs detached and can never change the local headline except to
	/// report a real revocation.
	func check(cert: CertificatePair) {
		guard !_isChecking else {
			return
		}

		_isChecking = true
		let token = UUID()
		_activeToken = token
		_setStatus(.checking)

		let local = Self._localCheck(cert: cert)
		lastChecked = Date()
		_isChecking = false

		switch local {
		case .missing(let reason):
			_setStatus(.unverified(reason: reason))
		case .invalid(let reason):
			_setStatus(.invalid(reason: reason))
		case .verdict(let details):
			// A revocation flagged by an earlier OCSP answer stands:
			// the local parse cannot un-revoke a certificate.
			if cert.revoked {
				_setStatus(.revoked(details: details))
				return
			}
			guard let expiry = details.effectiveExpiry else {
				_setStatus(.invalid(reason: .localized("ما گدرنا نقرا تاريخ انتهاء الشهادة")))
				return
			}
			if expiry <= Date() {
				_setStatus(.expired(details: details))
			} else if let daysLeft = details.daysLeft, daysLeft < Self.expiringSoonThresholdDays {
				_setStatus(.expiringSoon(details: details, onlineUnavailable: false))
				_runOCSPBestEffort(cert: cert, details: details, token: token)
			} else {
				_setStatus(.healthy(details: details, onlineUnavailable: false))
				_runOCSPBestEffort(cert: cert, details: details, token: token)
			}
		}
	}

	// MARK: - Local check

	private enum _LocalResult {
		/// No certificate files at all.
		case missing(reason: String?)
		/// Files exist but nothing usable could be read from them.
		case invalid(reason: String)
		/// At least one expiry date was read; the verdict follows.
		case verdict(details: LocalCertificateDetails)
	}

	/// Parses the .p12 and the .mobileprovision on device. The
	/// effective expiry is the earliest of the p12 expiry, the profile
	/// expiry, and the stored Core Data expiry — the conservative
	/// (earliest) date is the honest one to show.
	private static func _localCheck(cert: CertificatePair) -> _LocalResult {
		let provisionURL = Storage.shared.getFile(.provision, from: cert)
		let p12URL = Storage.shared.getFile(.certificate, from: cert)

		guard provisionURL != nil || p12URL != nil else {
			return .missing(reason: .localized("ملفات الشهادة مو موجودة"))
		}

		var details = LocalCertificateDetails()
		var problems: [String] = []

		if let p12URL {
			switch _readP12(at: p12URL, password: cert.password ?? "") {
			case .success(let p12):
				details.p12Expiry = p12.expiry
				details.p12Subject = p12.subject
				details.p12Issuer = p12.issuer
			case .failure(let error):
				details.p12Problem = error.reason
				problems.append(error.reason)
			}
		}

		if let provisionURL {
			// Full decode first (the same reader the hero card uses).
			if let decoded = Storage.shared.getProvisionFileDecoded(for: cert) {
				details.provisionExpiry = decoded.ExpirationDate
				details.provisionTeamName = decoded.TeamName
				details.provisionAppIDName = decoded.AppIDName
			} else {
				// The full decode needs every field; fall back to a
				// manual plist read of just the fields we need.
				let fallback = _readProvisionPlist(at: provisionURL)
				details.provisionExpiry = fallback.expiry
				details.provisionTeamName = fallback.teamName
				details.provisionAppIDName = fallback.appIDName
				if fallback.expiry == nil && fallback.teamName == nil && fallback.appIDName == nil {
					problems.append(.localized("ملف البروفايل ما ينقرا"))
				}
			}
		}

		let expiries = [details.p12Expiry, details.provisionExpiry, cert.expiration].compactMap { $0 }
		details.effectiveExpiry = expiries.min()
		if let expiry = details.effectiveExpiry {
			details.daysLeft = max(0, Int(expiry.timeIntervalSinceNow / 86400))
		}

		guard details.effectiveExpiry != nil else {
			// Nothing usable: report exactly why, not a guess.
			if problems.isEmpty {
				return .invalid(reason: .localized("ما گدرنا نقرا تاريخ انتهاء الشهادة"))
			}
			return .invalid(reason: problems.joined(separator: " — "))
		}
		return .verdict(details: details)
	}

	// MARK: - .p12 parsing

	private struct _P12Info {
		var expiry: Date?
		var subject: String?
		var issuer: String?
	}

	/// The .p12 could not be read. `String` cannot be a `Result`
	/// failure (it is not an `Error`), so the reason rides in this
	/// tiny type instead.
	private enum _P12Error: Error {
		case unreadable(String)
		var reason: String {
			switch self {
			case .unreadable(let message): return message
			}
		}
	}

	/// Imports the .p12 with the Security framework and reads the
	/// certificate's expiry, subject and issuer. Any failure returns
	/// the real reason instead of a made-up verdict.
	private static func _readP12(at url: URL, password: String) -> Result<_P12Info, _P12Error> {
		let unreadable = String.localized("ملف الشهادة ما ينقرا — أعد استيراد الشهادة")
		guard let data = try? Data(contentsOf: url) else {
			return .failure(.unreadable(unreadable))
		}

		var items: CFArray?
		let options: [String: Any] = [kSecImportExportPassphrase as String: password]
		let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
		guard status == errSecSuccess else {
			if status == errSecAuthFailed {
				return .failure(.unreadable(.localized("كلمة مرور الشهادة غلط")))
			}
			return .failure(.unreadable(unreadable))
		}
		guard
			let items,
			let item = (items as NSArray).firstObject as? [String: Any],
			let rawIdentity = item[kSecImportItemIdentity as String]
		else {
			return .failure(.unreadable(unreadable))
		}
		// SecIdentity is a CoreFoundation type: a conditional
		// downcast to it always succeeds, so the compiler rejects
		// `as?` here — the presence guard above is the real check,
		// and SecPKCS12Import guarantees this value is a SecIdentity.
		let identity = rawIdentity as! SecIdentity

		var certificate: SecCertificate?
		guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
			return .failure(.unreadable(unreadable))
		}

		var info = _P12Info()
		info.subject = SecCertificateCopySubjectSummary(certificate) as String?
		// SecCertificateCopyValues (and the kSecOID*/kSecPropertyKey*
		// constants) are macOS-only — they do not exist in the iOS
		// Security framework, even though `import Security` is
		// present. Read the same fields from the DER bytes with
		// swift-certificates (X509), already in the package graph
		// as a dependency of swift-nio-ssl.
		if let der = SecCertificateCopyData(certificate) as Data? {
			var decoder = DER.Decoder(derEncoded: [UInt8](der))
			if let x509 = try? Certificate(from: &decoder) {
				info.expiry = x509.notValidAfter
				info.subject = String(describing: x509.subject)
				info.issuer = String(describing: x509.issuer)
			}
		}
		return .success(info)
	}

	// MARK: - .mobileprovision parsing

	private struct _ProvisionInfo {
		var expiry: Date?
		var teamName: String?
		var appIDName: String?
	}

	/// Manual plist read of a .mobileprovision: the file is a CMS
	/// blob with an XML plist inside, so the XML part is extracted
	/// first (same approach as CertificateReader).
	private static func _readProvisionPlist(at url: URL) -> _ProvisionInfo {
		var info = _ProvisionInfo()
		guard
			let data = try? Data(contentsOf: url),
			let xmlRange = data.range(of: Data("<?xml".utf8))
		else {
			return info
		}
		let xmlData = data.subdata(in: xmlRange.lowerBound..<data.endIndex)
		guard let plist = try? PropertyListSerialization.propertyList(from: xmlData, format: nil) as? [String: Any] else {
			return info
		}
		info.expiry = plist["ExpirationDate"] as? Date
		info.teamName = plist["TeamName"] as? String
		info.appIDName = plist["AppIDName"] as? String
		return info
	}

	// MARK: - OCSP (best-effort secondary)

	/// Best-effort OCSP, run ONLY after the local check passed. It can
	/// only confirm the local verdict, or upgrade it to revoked when
	/// the responder really answers REVOKED. An unreachable responder
	/// or any other error keeps the local verdict and just marks the
	/// online check unavailable — it never becomes the headline.
	private func _runOCSPBestEffort(cert: CertificatePair, details: LocalCertificateDetails, token: UUID) {
		guard
			let provisionURL = Storage.shared.getFile(.provision, from: cert),
			let p12URL = Storage.shared.getFile(.certificate, from: cert)
		else {
			return
		}

		Zsign.checkRevokage(
			provisionPath: provisionURL.path,
			p12Path: p12URL.path,
			p12Password: cert.password ?? ""
		) { [weak self] status, _, _ in
			// checkCert's completion arrives on a URLSession thread.
			DispatchQueue.main.async {
				guard let self, self._activeToken == token else {
					return
				}
				switch status {
				case 0:
					// V_OCSP_CERTSTATUS_GOOD — local verdict confirmed.
					self._setOnlineAvailable(true, details: details)
				case 1:
					// V_OCSP_CERTSTATUS_REVOKED — mirror the stored
					// flag the Library already reads.
					cert.revoked = true
					Storage.shared.saveContext()
					self._setStatus(.revoked(details: details))
				default:
					// V_OCSP_CERTSTATUS_UNKNOWN and every error path
					// in checkCert report 2: no verdict, not a pass.
					// Keep the local verdict; note the online check
					// is unavailable.
					self._setOnlineAvailable(false, details: details)
				}
			}
		}
	}

	/// Re-publishes the current local verdict with the online-check
	/// availability flag. Only applies while the local verdict is
	/// still the current status.
	private func _setOnlineAvailable(_ available: Bool, details: LocalCertificateDetails) {
		switch status {
		case .healthy:
			_setStatus(.healthy(details: details, onlineUnavailable: !available))
		case .expiringSoon:
			_setStatus(.expiringSoon(details: details, onlineUnavailable: !available))
		default:
			break
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
