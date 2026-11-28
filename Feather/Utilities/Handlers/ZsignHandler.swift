//
//  ZsignHandler.swift
//  Zenith
//
//  Created by samara on 17.04.2025.
//

import Foundation
import Zsign
import UIKit

final class ZsignHandler {
	var hadError: Error?
	
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

		// Zenith v2.25: the provision flag was inverted across the
		// Swift/C++ boundary (proven 2026-11-28 with a Linux build
		// of the exact vendored zsign sources): removeProvisioning
		// defaults to false, so the old `!` passed true — zsign's
		// "exclude the profile" — and every signed bundle shipped
		// with NO embedded.mobileprovision, which installd rejects
		// at verification. Pass the option straight through.
		// The C++ half must land with this: bundle.cpp currently
		// writes the profile only `if (bRemoveProvision)`; restore
		// the upstream unconditional write there, or this half
		// alone changes nothing.
		let signed = Zsign.sign(
			appPath: _appUrl.relativePath,
			provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
			p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
			p12Password: cert.password ?? "",
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			removeProvision: _options.removeProvisioning,
			completion: { success in
				if !success {
					self.hadError = SigningFileHandlerError.signFailed
				}
			}
		)
		// Zenith v2.25: zsign() returns -1 WITHOUT calling the
		// completion on its early exits (bad path, certificate
		// init failure) — the old code threw the Bool away, so
		// hadError stayed nil and an unsigned bundle reached the
		// Library as if signed. A failed return with no error
		// recorded is a signing failure too.
		if !signed && hadError == nil {
			hadError = SigningFileHandlerError.signFailed
		}
	}
	
	func adhocSign() async throws {
		// Zenith v2.25: same inverted provision flag as sign()
		// (see above) — pass the option straight through.
		let signed = Zsign.sign(
			appPath: _appUrl.relativePath,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			adhoc: true,
			removeProvision: _options.removeProvisioning,
			completion: { success in
				if !success {
					self.hadError = SigningFileHandlerError.signFailed
				}
			}
		)
		// Zenith v2.25: same early-exit blind spot as sign() —
		// a failed return with no recorded error is a failure.
		if !signed && hadError == nil {
			hadError = SigningFileHandlerError.signFailed
		}
	}
}
