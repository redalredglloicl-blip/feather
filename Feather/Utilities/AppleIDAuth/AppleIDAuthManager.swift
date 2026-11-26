//
//  AppleIDAuthManager.swift
//  Zenith
//
//  Fetches a FREE Apple Developer certificate with the user's own Apple ID,
//  entirely on-device (no computer, no paid account, no paid service).
//
//  Flow: anisette -> Apple ID sign-in (+ 2FA when Apple asks) -> pick the
//  free team -> resolve a development certificate -> download the free
//  (wildcard) team provisioning profile -> build a .p12 + .mobileprovision
//  pair -> save it through Zenith's normal certificate import path.
//
//  The password is used only for this one sign-in and is never stored.
//  The session (AuthSession, Codable) is kept in the Keychain so a later
//  background refresh can fetch a new certificate without asking for the
//  password again. Signing out deletes it.
//
//  Honest limits (see ZENITH_MOD_PLAN.md §5): this flow has never run
//  against Apple from this workspace. The Apple handshake, the 2FA round
//  trip and the portal calls are only proven by a real build + device test.

import Foundation
import SideSign
import UIKit

// MARK: - Errors

enum AppleIDAuthError: Error, LocalizedError {
	case anisetteFailed(underlying: Error)
	case authenticationFailed(underlying: Error)
	case twoFactorCancelled
	case noTeam
	case certificateLimitReached(underlying: Error)
	case profileFailed(underlying: Error)
	case saveFailed(underlying: Error?)
	case sessionExpired
	case cancelled
	
	var errorDescription: String? {
		switch self {
		case .anisetteFailed(let error):
			return "Could not prepare device identity: \(error.localizedDescription)"
		case .authenticationFailed(let error):
			return "Apple ID sign-in failed: \(error.localizedDescription)"
		case .twoFactorCancelled:
			return "Verification was cancelled."
		case .noTeam:
			return "No developer team was found for this Apple ID."
		case .certificateLimitReached(let error):
			return "Apple refused a new certificate: \(error.localizedDescription)"
		case .profileFailed(let error):
			return "Could not download a provisioning profile: \(error.localizedDescription)"
		case .saveFailed(let error):
			return "Could not save the certificate: \(error?.localizedDescription ?? "unknown error")"
		case .sessionExpired:
			return "The saved Apple ID session expired. Sign in again."
		case .cancelled:
			return "Cancelled."
		}
	}
}

// MARK: - Sendable boxes (bridge the @Sendable auth callbacks to the UI)

/// Holds one pending 2FA code request. The SideSign verification handler
/// runs off the main actor, so it must not capture MainActor state.
final class VerificationCodeBox: @unchecked Sendable {
	private let _lock = NSLock()
	private var _continuation: CheckedContinuation<String, Error>?
	
	func awaitCode() async throws -> String {
		try await withCheckedThrowingContinuation { continuation in
			_lock.withLock {
				_continuation = continuation
			}
		}
	}
	
	func submit(_ code: String) {
		_lock.withLock {
			_continuation?.resume(returning: code)
			_continuation = nil
		}
	}
	
	func cancel() {
		_lock.withLock {
			_continuation?.resume(throwing: AppleIDAuthError.twoFactorCancelled)
			_continuation = nil
		}
	}
}

/// Holds one pending certificate-revocation decision from the user.
final class RevocationDecisionBox: @unchecked Sendable {
	private let _lock = NSLock()
	private var _continuation: CheckedContinuation<CertificateProvisioningFlow.RevokeDecision, Error>?
	
	func awaitDecision() async throws -> CertificateProvisioningFlow.RevokeDecision {
		try await withCheckedThrowingContinuation { continuation in
			_lock.withLock {
				_continuation = continuation
			}
		}
	}
	
	func submit(_ decision: CertificateProvisioningFlow.RevokeDecision) {
		_lock.withLock {
			_continuation?.resume(returning: decision)
			_continuation = nil
		}
	}
	
	func cancel() {
		_lock.withLock {
			_continuation?.resume(throwing: AppleIDAuthError.cancelled)
			_continuation = nil
		}
	}
}

// MARK: - Manager

@MainActor
final class AppleIDAuthManager: ObservableObject {
	static let shared = AppleIDAuthManager()
	
	// MARK: - Phase
	
	enum Phase {
		case idle
		case fetchingAnisette
		case signingIn
		case needsVerification
		case fetchingTeam
		case provisioning
		case saving
		case done
		case failed
	}
	
	@Published var phase: Phase = .idle
	@Published var statusText: String = ""
	@Published var errorMessage: String?
	@Published var verificationRequest: TwoFactorRequest?
	@Published var revocationRequest: [X509Certificate]?
	@Published var fetchedCertificate: CertificatePair?
	
	private var _verificationBox: VerificationCodeBox?
	private var _revocationBox: RevocationDecisionBox?
	private var _currentTask: Task<Void, Never>?
	
	private static let _sessionService = "zenith.appleid.session"
	private static let _xcodeVersion = "16.0" // client identifier sent to Apple, not a local Xcode install
	
	private init() {}
	
	// MARK: - Status text
	
	var localizedStatusText: String {
		switch phase {
		case .idle:
			return .localized("Sign in with your Apple ID to fetch a free certificate.")
		case .fetchingAnisette:
			return .localized("Preparing device identity…")
		case .signingIn:
			return .localized("Signing in…")
		case .needsVerification:
			return .localized("Enter the verification code.")
		case .fetchingTeam:
			return .localized("Finding your free team…")
		case .provisioning:
			return .localized("Requesting a free certificate from Apple…")
		case .saving:
			return .localized("Saving the certificate…")
		case .done:
			return .localized("Certificate ready.")
		case .failed:
			return errorMessage ?? .localized("Something went wrong.")
		}
	}
	
	// MARK: - Entry point
	
	/// Starts the whole flow in a cancellable task. The caller observes
	/// `phase` / `verificationRequest` / `revocationRequest`.
	func startFetchingCertificate(appleID: String, password: String) {
		_reset()
		_currentTask = Task {
			// Errors are already surfaced through `phase` / `errorMessage`.
			_ = try? await _fetchFreeCertificate(appleID: appleID, password: password)
		}
	}
	
	func cancel() {
		_currentTask?.cancel()
		_currentTask = nil
		_verificationBox?.cancel()
		_revocationBox?.cancel()
		_verificationBox = nil
		_revocationBox = nil
		verificationRequest = nil
		revocationRequest = nil
		phase = .idle
		statusText = ""
	}
	
	func submitVerificationCode(_ code: String) {
		verificationRequest = nil
		phase = .signingIn
		_verificationBox?.submit(code.trimmingCharacters(in: .whitespacesAndNewlines))
	}
	
	func cancelVerification() {
		verificationRequest = nil
		_verificationBox?.cancel()
	}
	
	func resolveRevocation(_ decision: CertificateProvisioningFlow.RevokeDecision) {
		revocationRequest = nil
		phase = .provisioning
		_revocationBox?.submit(decision)
	}
	
	// MARK: - Stored session (for background refresh)
	
	/// The last successful Apple ID session, if any. Background refresh
	/// uses it to fetch a new certificate without asking for the password.
	var storedSession: AuthSession? {
		guard
			let data = KeychainHelper.load(
				service: Self._sessionService,
				account: _storedSessionAccount
			),
			let session = try? JSONDecoder().decode(AuthSession.self, from: data)
		else {
			return nil
		}
		return session
	}
	
	/// The Apple ID the stored session belongs to, if any.
	var storedAppleID: String? {
		UserDefaults.standard.string(forKey: "Zenith.appleIDSessionAccount")
	}
	
	private var _storedSessionAccount: String {
		storedAppleID ?? "apple-id"
	}
	
	func signOut() {
		KeychainHelper.delete(service: Self._sessionService, account: _storedSessionAccount)
		UserDefaults.standard.removeObject(forKey: "Zenith.appleIDSessionAccount")
	}
	
	// MARK: - Flow
	
	private func _fetchFreeCertificate(appleID: String, password: String) async throws -> CertificatePair {
		do {
			phase = .fetchingAnisette
			let anisette: AnisetteData
			do {
				anisette = try await AnisetteManager.shared.fetchAnisetteData()
			} catch {
				throw AppleIDAuthError.anisetteFailed(underlying: error)
			}
			
			phase = .signingIn
			let authSession: AuthSession
			do {
				authSession = try await _authenticate(
					appleID: appleID,
					password: password,
					anisetteData: anisette
				)
			} catch let error as AppleIDAuthError {
				throw error
			} catch {
				throw AppleIDAuthError.authenticationFailed(underlying: error)
			}
			
			_saveSession(authSession, for: appleID)
			
			let pair = try await _provisionCertificate(authSession: authSession)
			
			fetchedCertificate = pair
			phase = .done
			return pair
		} catch {
			if error is CancellationError {
				phase = .idle
			} else if let authError = error as? AppleIDAuthError, case .cancelled = authError {
				phase = .idle
			} else {
				errorMessage = error.localizedDescription
				phase = .failed
			}
			throw error
		}
	}
	
	/// Fetches a fresh free certificate using the session saved in the
	/// Keychain by an earlier sign-in — no password, no UI. Used by
	/// background auto-refresh. Throws `.sessionExpired` when there is
	/// no stored session, or when Apple rejects it (the user must sign
	/// in again from the Certificates screen).
	func refreshCertificateWithStoredSession() async throws -> CertificatePair {
		guard let authSession = storedSession else {
			throw AppleIDAuthError.sessionExpired
		}
		do {
			return try await _provisionCertificate(authSession: authSession)
		} catch let error as AppleIDAuthError {
			throw error
		} catch {
			// A stored session can go stale at any time; treat any
			// portal failure as an expired session so the UI can ask
			// the user to sign in again instead of retrying forever.
			throw AppleIDAuthError.sessionExpired
		}
	}
	
	/// Team pick -> resolve certificate -> download team profile -> save.
	/// Shared by the interactive sign-in flow and background refresh.
	private func _provisionCertificate(authSession: AuthSession) async throws -> CertificatePair {
		do {
			phase = .fetchingTeam
			let teams: [Team]
			do {
				teams = try await DeveloperPortal.shared.fetchTeams(
					for: authSession.account,
					session: authSession.session
				)
			} catch {
				throw AppleIDAuthError.authenticationFailed(underlying: error)
			}
			// Free only, by design: prefer the free team even if the
			// account also has a paid one.
			guard let team = teams.first(where: { $0.type == .free }) ?? teams.first else {
				throw AppleIDAuthError.noTeam
			}
			
			phase = .provisioning
			let keyStore = try await CertificateProvisioningFlow.shared.resolveCertificate(
				for: team,
				session: authSession.session,
				machineName: _machineName(),
				revocationHandler: { [weak self] certificates in
					guard let self else { throw AppleIDAuthError.cancelled }
					return try await self._askRevocation(for: certificates)
				}
			)
			
			let profile: ProvisioningProfile
			do {
				profile = try await _downloadTeamProfile(for: team, session: authSession.session)
			} catch {
				throw AppleIDAuthError.profileFailed(underlying: error)
			}
			
			phase = .saving
			return try await _saveCertificatePair(keyStore: keyStore, profile: profile)
		} catch {
			// AppleIDAuthError values are already honest; anything else
			// (e.g. a raw portal error from a revoke) is rethrown as-is
			// so callers can classify it instead of mislabelling it.
			throw error
		}
	}
	
	private func _authenticate(
		appleID: String,
		password: String,
		anisetteData: AnisetteData
	) async throws -> AuthSession {
		let box = VerificationCodeBox()
		_verificationBox = box
		
		let handler: DeveloperPortal.VerificationHandler = { [box] request in
			// Tell the UI which verification Apple wants (fire-and-forget).
			Task { @MainActor in
				AppleIDAuthManager.shared.verificationRequest = request
				AppleIDAuthManager.shared.phase = .needsVerification
			}
			
			switch request {
			case .selectDeliveryMethod:
				// Prefer a trusted device; if none exists Apple answers
				// with a new request (SMS/voice) and this handler runs again.
				return .requestTrustedDevice
			case .trustedDevice, .sms, .voice:
				let code = try await box.awaitCode()
				return .verificationCode(code)
			}
		}
		
		return try await DeveloperPortal.shared.authenticate(
			appleID: appleID,
			password: password,
			anisetteData: anisetteData,
			xcodeVersion: Self._xcodeVersion,
			verificationHandler: handler
		)
	}
	
	private func _askRevocation(
		for certificates: [X509Certificate]
	) async throws -> CertificateProvisioningFlow.RevokeDecision {
		let box = RevocationDecisionBox()
		_revocationBox = box
		
		await MainActor.run {
			self.revocationRequest = certificates
			self.phase = .provisioning
		}
		
		return try await box.awaitDecision()
	}
	
	private func _downloadTeamProfile(
		for team: Team,
		session: Session
	) async throws -> ProvisioningProfile {
		// Free accounts sign with the wildcard team profile (bundle ID "*"),
		// which covers any app. Reuse it when it already exists.
		let appIDs = try await DeveloperPortal.shared.fetchAppIDs(for: team, session: session)
		let wildcard: AppID
		if let existing = appIDs.first(where: { $0.bundleIdentifier == "*" }) {
			wildcard = existing
		} else {
			wildcard = try await DeveloperPortal.shared.addAppID(
				withName: "Zenith",
				bundleIdentifier: "*",
				team: team,
				session: session
			)
		}
		
		let deviceType: DeviceType = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
		
		return try await DeveloperPortal.shared.downloadProvisioningProfile(
			for: wildcard,
			isTeamProfile: true,
			subPlatform: nil,
			deviceType: deviceType,
			team: team,
			session: session
		)
	}
	
	private func _saveCertificatePair(
		keyStore: KeyStore,
		profile: ProvisioningProfile
	) async throws -> CertificatePair {
		// A random password for the exported .p12; Zenith stores it with
		// the certificate pair, exactly like an imported certificate.
		let p12Password = UUID().uuidString
		
		let p12Data: Data
		do {
			p12Data = try PKCS12Exporter.build(keyStore: keyStore, password: p12Password)
		} catch {
			throw AppleIDAuthError.saveFailed(underlying: error)
		}
		
		let workDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("ZenithAppleID_\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workDir) }
		
		let p12URL = workDir.appendingPathComponent("cert.p12")
		let provisionURL = workDir.appendingPathComponent("cert.mobileprovision")
		try p12Data.write(to: p12URL)
		try profile.data.write(to: provisionURL)
		
		let beforeUUIDs = Set(Storage.shared.getAllCertificates().compactMap(\.uuid))
		
		do {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				Zenith.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: p12Password,
					certificateName: "Apple ID"
				) { error in
					if let error {
						continuation.resume(throwing: error)
					} else {
						continuation.resume()
					}
				}
			}
		} catch {
			throw AppleIDAuthError.saveFailed(underlying: error)
		}
		
		guard
			let pair = Storage.shared.getAllCertificates().first(where: {
				guard let uuid = $0.uuid else { return false }
				return !beforeUUIDs.contains(uuid)
			})
		else {
			throw AppleIDAuthError.saveFailed(underlying: nil)
		}
		
		return pair
	}
	
	private func _saveSession(_ session: AuthSession, for appleID: String) {
		guard let data = try? JSONEncoder().encode(session) else { return }
		KeychainHelper.save(data, service: Self._sessionService, account: appleID)
		UserDefaults.standard.set(appleID, forKey: "Zenith.appleIDSessionAccount")
	}
	
	private func _machineName() -> String {
		"Zenith - \(UIDevice.current.name)"
	}
	
	private func _reset() {
		_currentTask?.cancel()
		_currentTask = nil
		_verificationBox?.cancel()
		_revocationBox?.cancel()
		_verificationBox = nil
		_revocationBox = nil
		verificationRequest = nil
		revocationRequest = nil
		fetchedCertificate = nil
		errorMessage = nil
		phase = .idle
		statusText = ""
	}
}
