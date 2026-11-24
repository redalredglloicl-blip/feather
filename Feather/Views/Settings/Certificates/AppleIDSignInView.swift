
//
//  AppleIDSignInView.swift
//  Feather
//
//  Sign in with the user's own Apple ID to fetch a FREE Apple Developer
//  certificate (7 days, max 3 apps) entirely on-device. No computer,
//  no paid account, no paid service.
//
//  The password is used only for this one sign-in and is never stored.
//  Only the session (AuthSession) is kept in the Keychain so a later
//  background refresh can fetch a new certificate without the password.
//
//  Honest limits: this flow has never run against Apple from this
//  workspace. The handshake, the 2FA round trip and the portal calls
//  are only proven by a real build + device test (see FEATHER_MOD_PLAN.md §5).

import SwiftUI
import NimbleViews
import SideSign

// MARK: - View
struct AppleIDSignInView: View {
	@Environment(\.dismiss) private var dismiss
	@StateObject private var _manager = AppleIDAuthManager.shared
	
	@State private var _appleID: String = AppleIDAuthManager.shared.storedAppleID ?? ""
	@State private var _password: String = ""
	@State private var _verificationCode: String = ""
	@State private var _isVerificationAlertPresenting = false
	@State private var _isRevocationSheetPresenting = false
	
	private var _isBusy: Bool {
		switch _manager.phase {
		case .idle, .done, .failed:
			return false
		default:
			return true
		}
	}
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Certificate from Apple"), displayMode: .inline) {
			Form {
				NBSection(.localized("Apple ID")) {
					TextField(.localized("Apple ID"), text: $_appleID)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.keyboardType(.emailAddress)
					SecureField(.localized("Password"), text: $_password)
				} footer: {
					Text(.localized("Your Apple ID password is used only for this sign-in and is never stored."))
				}
				
				Section {
					Button {
						_manager.startFetchingCertificate(appleID: _appleID, password: _password)
					} label: {
						HStack {
							if _isBusy {
								ProgressView()
							}
							Text(.localized("Fetch Certificate"))
						}
						.frame(maxWidth: .infinity, alignment: .center)
					}
					.disabled(_appleID.isEmpty || _password.isEmpty || _isBusy)
				} footer: {
					Text(_manager.localizedStatusText)
						.foregroundStyle(_manager.phase == .failed ? .red : .secondary)
				}
				
				if let error = _manager.errorMessage, _manager.phase == .failed {
					Section {
						Text(error)
							.font(.footnote)
							.foregroundStyle(.red)
					}
				}
			}
			.toolbar {
				NBToolbarButton(
					.localized("Cancel"),
					style: .text,
					placement: .cancellationAction
				) {
					_manager.cancel()
					dismiss()
				}
			}
			.onChange(of: _manager.phase) { phase in
				if phase == .done {
					dismiss()
				}
			}
			.onChange(of: _manager.verificationRequest != nil) { needsCode in
				_isVerificationAlertPresenting = needsCode
			}
			.onChange(of: _manager.revocationRequest != nil) { needsDecision in
				_isRevocationSheetPresenting = needsDecision
			}
			.alert(.localized("Verification Code"), isPresented: $_isVerificationAlertPresenting) {
				TextField(.localized("Verification Code"), text: $_verificationCode)
					.keyboardType(.numberPad)
				Button(.localized("Cancel"), role: .cancel) {
					_manager.cancelVerification()
				}
				Button(.localized("Verify")) {
					_manager.submitVerificationCode(_verificationCode)
					_verificationCode = ""
				}
			} message: {
				Text(_verificationMessage)
			}
			.sheet(isPresented: $_isRevocationSheetPresenting) {
				_revocationSheet()
			}
		}
	}
	
	private var _verificationMessage: String {
		guard let request = _manager.verificationRequest else {
			return .localized("Enter the verification code sent to your trusted device.")
		}
		switch request {
		case .trustedDevice:
			return .localized("Enter the verification code shown on your trusted device.")
		case .sms:
			return .localized("Enter the verification code sent by text message.")
		case .voice:
			return .localized("Enter the verification code from the phone call.")
		case .selectDeliveryMethod:
			return .localized("Choose how Apple sends your verification code.")
		}
	}
	
	@ViewBuilder
	private func _revocationSheet() -> some View {
		NBNavigationView(.localized("Certificate Already Exists"), displayMode: .inline) {
			Form {
				Section {
					Text(.localized("This Apple ID already has development certificates. Apple allows only a limited number of free certificates."))
						.font(.subheadline)
					if let certs = _manager.revocationRequest {
						ForEach(certs, id: \.serialNumberHex) { cert in
							VStack(alignment: .leading, spacing: 2) {
								Text(cert.commonName)
									.font(.headline)
								if let notBefore = cert.notBefore {
									Text(notBefore.formatted(date: .abbreviated, time: .omitted))
										.font(.footnote)
										.foregroundStyle(.secondary)
								}
							}
						}
					}
				}
				Section {
					Button(.localized("Revoke Oldest & Continue"), role: .destructive) {
						_isRevocationSheetPresenting = false
						_manager.resolveRevocation(.revokeOldest)
					}
					Button(.localized("Cancel"), role: .cancel) {
						_isRevocationSheetPresenting = false
						_manager.cancel()
					}
				} footer: {
					Text(.localized("Revoking deletes the oldest certificate from your Apple ID. Apps signed with it stop working."))
				}
			}
		}
	}
}
