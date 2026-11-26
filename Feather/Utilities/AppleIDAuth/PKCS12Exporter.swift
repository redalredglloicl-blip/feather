//
//  PKCS12Exporter.swift
//  Zenith
//
//  Builds a .p12 file from a SideSign KeyStore (certificate + private key)
//  so a freshly fetched Apple certificate can be stored through Zenith's
//  normal certificate import path (Zenith.handleCertificateFiles), exactly
//  like a certificate the user imported from Files.
//
//  Uses SideSign's own KeyStore.exportP12 — CodeSignKit is only a
//  transitive dependency of SideSign and cannot be imported by the
//  Zenith target (that was a build failure: "No such module
//  'CodeSignKit'").

import Foundation
import SideSign

enum PKCS12Exporter {
	static func build(keyStore: KeyStore, password: String) throws -> Data {
		try keyStore.exportP12(password: password)
	}
}
