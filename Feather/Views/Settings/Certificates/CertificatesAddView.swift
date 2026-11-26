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
						isPresented: $_isImportingP12Presenting
					)
					_importRow(
						.localized("Import Provisioning File"),
						file: _provisionURL,
						isPresented: $_isImportingMobileProvisionPresenting
					)
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
			// Zenith v2.8: stars on this sheet too — same pattern as
			// the tab roots (clear scroll background, starfield behind).
			.scrollContentBackground(.hidden)
			.background(Color.clear)
			.starfieldBackground()
			.listRowBackground(Color.clear)
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
			// Certificate file pickers: FileImporterRepresentableView
			// (UIViewControllerRepresentable around
			// UIDocumentPickerViewController, delegate = coordinator)
			// hosted as sheet content — the exact upstream approach
			// that worked before ("مثل قبل"). The native SwiftUI
			// .fileImporter is NOT used here: on iOS 27, presented
			// from inside this .medium-detent sheet, it opened the
			// Files picker but swallowed the tap — the file row showed
			// the long-press menu instead of selecting, and
			// onCompletion never fired, so the import silently did
			// nothing. The representable creates the picker directly
			// with an explicit delegate, so selection reaches us.
			// Sheets live on the outer navigation view (not on the
			// Form rows), and .ignoresSafeArea() keeps the picker
			// full-height (upstream fix 2db6a50).
			.sheet(isPresented: $_isImportingP12Presenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.p12],
					onDocumentsPicked: { urls in
						_handlePickedURLs(urls, forP12: true)
					}
				)
				.ignoresSafeArea()
			}
			.sheet(isPresented: $_isImportingMobileProvisionPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.mobileProvision],
					onDocumentsPicked: { urls in
						_handlePickedURLs(urls, forP12: false)
					}
				)
				.ignoresSafeArea()
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
		isPresented: Binding<Bool>
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
		// No .fileImporter here on purpose (see the picker sheets
		// above): the native modifier's onCompletion never fires on
		// iOS 27 from inside this sheet. The row only flips the
		// presenting binding; the representable picker does the work.
	}
}

// MARK: - Extension: View (import)
extension CertificatesAddView {
	/// Called by the document-picker coordinator with the picked URLs
	/// (empty array = user cancelled). The picker sheet is dismissed
	/// explicitly on every path: the picker's own self-dismissal is
	/// not relied on, so a cancelled or completed pick can never leave
	/// this sheet hanging. Picked files are copied into the sandbox
	/// (see _copyImportedFileToSandbox) and the row shows the filename
	/// with a green checkmark; once both files are set, Save enables.
	private func _handlePickedURLs(
		_ urls: [URL],
		forP12: Bool
	) {
		defer {
			if forP12 {
				_isImportingP12Presenting = false
			} else {
				_isImportingMobileProvisionPresenting = false
			}
		}
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
	}
	
	/// Copies a file picked from the Files picker into the app sandbox.
	/// The picker (asCopy: true) hands back a URL in a temp location;
	/// the later reads (`checkPasswordForCertificate` reads by path
	/// through C functions, `handleCertificateFiles` copies with
	/// FileManager) never claim scoped access, and the temp copy can
	/// be cleaned up, so storing the picked URL as-is made the import
	/// silently die. Returns the sandbox-local copy, or nil (after
	/// showing an alert) on failure.
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
