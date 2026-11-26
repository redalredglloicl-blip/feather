//
//  CertificatesAddView.swift
//  Zenith
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers

// MARK: - View
struct CertificatesAddView: View {
	@Environment(\.dismiss) private var dismiss
	
	@State private var _p12URL: URL? = nil
	@State private var _provisionURL: URL? = nil
	@State private var _p12Password: String = ""
	@State private var _certificateName: String = ""
	
	@State private var _isImportingP12Presenting = false
	@State private var _isImportingMobileProvisionPresenting = false
	@State private var _isAppleIDSignInPresenting = false
	
	var saveButtonDisabled: Bool {
		_p12URL == nil || _provisionURL == nil
	}
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("New Certificate"), displayMode: .inline) {
			Form {
				NBSection(.localized("Files")) {
					_importButton(.localized("Import Certificate File"), file: _p12URL) {
						_isImportingP12Presenting = true
					}
					_importButton(.localized("Import Provisioning File"), file: _provisionURL) {
						_isImportingMobileProvisionPresenting = true
					}
				}
				NBSection(.localized("Certificate from Apple")) {
					Button {
						_isAppleIDSignInPresenting = true
					} label: {
						Label(.localized("Certificate from Apple"), systemImage: "apple.logo")
					}
				} footer: {
					Text(.localized("Get a free certificate from Apple with your Apple ID"))
				}
				
				NBSection(.localized("Password")) {
					SecureField(.localized("Enter Password"), text: $_p12Password)
				} footer: {
					Text(.localized("Enter the password associated with the private key. Leave it blank if theres no password required."))
				}
				
				Section {
					TextField(.localized("Nickname (Optional)"), text: $_certificateName)
				}
			}
			.toolbar {
				NBToolbarButton(role: .cancel)
				
				NBToolbarButton(
					.localized("Save"),
					style: .text,
					placement: .confirmationAction,
					isDisabled: saveButtonDisabled
				) {
					_saveCertificate()
				}
			}
			.sheet(isPresented: $_isAppleIDSignInPresenting) {
				AppleIDSignInView()
					.zenithSheetBackground()
			}
			// Native fileImporter, NOT a nested sheet hosting a
			// UIDocumentPicker: the picker-as-sheet-content pattern
			// presented a black, hanging sheet on iOS 27 (the
			// certificate import never opened). The system modifier
			// presents the Files picker directly from this sheet.
			.fileImporter(
				isPresented: $_isImportingP12Presenting,
				allowedContentTypes: [.p12],
				allowsMultipleSelection: false
			) { result in
				if case let .success(urls) = result,
				   let selectedFileURL = urls.first {
					_p12URL = selectedFileURL
				}
			}
			.fileImporter(
				isPresented: $_isImportingMobileProvisionPresenting,
				allowedContentTypes: [.mobileProvision],
				allowsMultipleSelection: false
			) { result in
				if case let .success(urls) = result,
				   let selectedFileURL = urls.first {
					_provisionURL = selectedFileURL
				}
			}
		}
	}
}

// MARK: - Extension: View
extension CertificatesAddView {
	@ViewBuilder
	private func _importButton(
		_ title: String,
		file: URL?,
		action: @escaping () -> Void
	) -> some View {
		Button(title) {
			action()
		}
		.foregroundColor(file == nil ? .accentColor : .disabled())
		.disabled(file != nil)
		.animation(.easeInOut(duration: 0.3), value: file != nil)
	}
}

// MARK: - Extension: View (import)
extension CertificatesAddView {
	private func _saveCertificate() {
		guard
			let p12URL = _p12URL,
			let provisionURL = _provisionURL,
			Zenith.checkPasswordForCertificate(for: p12URL, with: _p12Password, using: provisionURL)
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("Bad Password"),
				message: .localized("Please check the password and try again.")
			)
			return
		}
		
		Zenith.handleCertificateFiles(
			p12URL: p12URL,
			provisionURL: provisionURL,
			p12Password: _p12Password,
			certificateName: _certificateName
		) { _ in
			dismiss()
		}
	}
}

