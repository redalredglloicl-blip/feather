//
//  CertificateProvisioningFlow.swift
//  Zenith
//
//  Resolves a free iOS Development certificate for a team: reuse the portal
//  state when possible, request a new certificate when there is none, and
//  only revoke an old certificate after the user explicitly agrees.
//
//  Architecture mirrors the well-known AltStore/SideStore flow (fetch ->
//  request-or-revoke -> request); the code itself is original.

import Foundation
import SideSign

final class CertificateProvisioningFlow {
	static let shared = CertificateProvisioningFlow()
	
	enum RevokeDecision {
		/// Revoke the oldest iOS Development certificate, then request a new one.
		case revokeOldest
		/// Do not touch existing certificates.
		case cancel
	}
	
	/// Asked when the portal already has development certificates.
	/// The UI presents the list and returns the user's decision.
	typealias RevocationHandler = ([X509Certificate]) async throws -> RevokeDecision
	
	private init() {}
	
	/// Returns a usable development certificate (as a KeyStore holding the
	/// certificate + its private key) for the given free team.
	func resolveCertificate(
		for team: Team,
		session: Session,
		machineName: String,
		revocationHandler: RevocationHandler? = nil
	) async throws -> KeyStore {
		let portalCertificates = try await DeveloperPortal.shared.fetchCertificates(
			for: team,
			session: session
		)
		
		let developmentCertificates = portalCertificates.filter { certificate in
			let name = certificate.name.lowercased()
			return name.contains("ios development") || name.contains("iphone developer")
		}
		
		// Nothing on the portal: ask Apple for a fresh certificate.
		guard !developmentCertificates.isEmpty else {
			return try await _requestCertificate(
				for: team,
				session: session,
				machineName: machineName
			)
		}
		
		// Certificates already exist. Never revoke silently: the user
		// decides, or we try requesting a new one and surface Apple's
		// answer (e.g. the free-account limit) honestly.
		guard let revocationHandler else {
			return try await _requestCertificate(
				for: team,
				session: session,
				machineName: machineName
			)
		}
		
		switch try await revocationHandler(developmentCertificates) {
		case .revokeOldest:
			if let oldest = developmentCertificates.min(by: {
				($0.notBefore ?? .distantPast) < ($1.notBefore ?? .distantPast)
			}) {
				_ = try await DeveloperPortal.shared.revokeCertificate(
					oldest,
					for: team,
					session: session
				)
			}
			
			return try await _requestCertificate(
				for: team,
				session: session,
				machineName: machineName
			)
			
		case .cancel:
			throw AppleIDAuthError.cancelled
		}
	}
	
	private func _requestCertificate(
		for team: Team,
		session: Session,
		machineName: String
	) async throws -> KeyStore {
		do {
			return try await DeveloperPortal.shared.addCertificate(
				machineName: machineName,
				type: .development,
				to: team,
				session: session
			)
		} catch {
			throw AppleIDAuthError.certificateLimitReached(underlying: error)
		}
	}
}
