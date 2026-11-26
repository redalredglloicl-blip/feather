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
	
	@State private var _importErrorMessage: String = ""
	@State private var _isImportErrorPresenting = false
	
	var saveButtonDisabled: Bool {
		_p12URL == nil || _provisionURL == nil
	}
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("New Certificate"), displayMode: .inline) {
			Form {
				NBSection(.localized("Files")) {
					_importRow(
						.localized("Import Certificate File"),
						file: _p12URL,
						isPresented: $_isImportingP12Presenting,
						allowedContentTypes: [.p12]
					) { result in
						_handleImportedFile(result, forP12: true)
					}
					_importRow(
						.localized("Import Provisioning File"),
						file: _provisionURL,
						isPresented: $_isImportingMobileProvisionPresenting,
						allowedContentTypes: [.mobileProvision]
					) { result in
						_handleImportedFile(result, forP12: false)
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
			.alert(.localized("Import Failed"), isPresented: $_isImportErrorPresenting) {
				Button(.localized("OK"), role: .cancel) { }
			} message: {
				Text(_importErrorMessage)
			}
		}
	}
}

// MARK: - Extension: View
extension CertificatesAddView {
	@ViewBuilder
	private func _importRow(
		_ title: String,
		file: URL?,
		isPresented: Binding<Bool>,
		allowedContentTypes: [UTType],
		onResult: @escaping (Result<[URL], Error>) -> Void
	) -> some View {
		Button {
			isPresented.wrappedValue = true
		} label: {
			HStack {
				Text(title)
					.foregroundColor(file == nil ? .accentColor : .secondary)
				Spacer()
				if let file = file {
					Text(file.lastPathComponent)
						.font(.footnote)
						.foregroundColor(.secondary)
						.lineLimit(1)
					Image(systemName: "checkmark.circle.fill")
						.foregroundColor(.green)
				}
			}
		}
		.disabled(file != nil)
		.animation(.easeInOut(duration: 0.3), value: file != nil)
		// Native fileImporter, NOT a nested sheet hosting a
		// UIDocumentPicker: the picker-as-sheet-content pattern
		// presented a black, hanging sheet on iOS 27 (the
		// certificate import never opened). The system modifier
		// presents the Files picker directly from this sheet.
		// Each importer lives on its own row view: two .fileImporter
		// modifiers on one shared host view is a fragile pattern.
		.fileImporter(
			isPresented: isPresented,
			allowedContentTypes: allowedContentTypes,
			allowsMultipleSelection: false,
			onCompletion: onResult
		)
	}
}

// MARK: - Extension: View (import)
extension CertificatesAddView {
	private func _handleImportedFile(
		_ result: Result<[URL], Error>,
		forP12: Bool
	) {
		switch result {
		case .success(let urls):
			guard let selectedFileURL = urls.first else {
				return
			}
			guard let localURL = _copyImportedFileToSandbox(selectedFileURL) else {
				return
			}
			if forP12 {
				_p12URL = localURL
			} else {
				_provisionURL = localURL
			}
		case .failure(let error):
			_showImportError(error.localizedDescription)
		}
	}
	
	/// Copies a file picked from the Files picker into the app sandbox.
	/// `.fileImporter` hands back a security-scoped URL outside the
	/// sandbox; the later reads (`checkPasswordForCertificate` reads by
	/// path through C functions, `handleCertificateFiles` copies with
	/// FileManager) never claim scoped access, so storing the picked
	/// URL as-is made the import silently die. Returns the sandbox-local
	/// copy, or nil (after showing an alert) on failure.
	private func _copyImportedFileToSandbox(_ sourceURL: URL) -> URL? {
		guard sourceURL.startAccessingSecurityScopedResource() else {
			_showImportError(.localized("Could not access the selected file. Please try again."))
			return nil
		}
		defer { sourceURL.stopAccessingSecurityScopedResource() }
		
		let importDirectory = URL.documentsDirectory.appendingPathComponent("ZenithCertImport")
		let destinationURL = importDirectory.appendingPathComponent(sourceURL.lastPathComponent)
		
		do {
			try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
			if FileManager.default.fileExists(atPath: destinationURL.path) {
				try FileManager.default.removeItem(at: destinationURL)
			}
			try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
			return destinationURL
		} catch {
			_showImportError(error.localizedDescription)
			return nil
		}
	}
	
	private func _showImportError(_ message: String) {
		_importErrorMessage = message
		_isImportErrorPresenting = true
	}
	
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
