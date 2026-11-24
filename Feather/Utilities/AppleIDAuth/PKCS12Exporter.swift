//
//  PKCS12Exporter.swift
//  Feather
//
//  Builds a .p12 file from a SideSign KeyStore (certificate + private key)
//  so a freshly fetched Apple certificate can be stored through Feather's
//  normal certificate import path (FR.handleCertificateFiles), exactly
//  like a certificate the user imported from Files.
//
//  Uses CodeSignKit's PKCS12Builder (verified API). The .p12 password is a
//  random UUID generated per certificate and stored with the pair.

import Foundation
import CodeSignKit
import SideSign

enum PKCS12Exporter {
	static func build(keyStore: KeyStore, password: String) throws -> Data {
		try PKCS12Builder.build(
			certificateDER: keyStore.certificate.rawDER,
			privateKeyDER: keyStore.privateKey,
			password: password
		)
	}
}
