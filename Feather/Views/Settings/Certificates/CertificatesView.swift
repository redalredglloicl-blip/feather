//
//  CertificatesView.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
import UIKit
import NimbleViews

// MARK: - View
struct CertificatesView: View {
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	
	@State private var _isAddingPresenting = false
	@State private var _isRenamingPresenting = false
	@State private var _isSelectedInfoPresenting: CertificatePair?
	@State private var _certToRename: CertificatePair?
	@State private var _newNickname: String = ""
	@State private var _isRefreshing = false
	@State private var _refreshReport: AutoRefreshReport?
	@State private var _isRefreshResultPresenting = false
	@State private var _isSelfRefreshConfirmPresenting = false
	@State private var _selfRefreshResult: String?
	@State private var _isSelfRefreshResultPresenting = false
	@AppStorage("Zenith.dnsProtectionInstalled") private var _dnsProtectionInstalled = false
	@State private var _isProfileNotFoundPresenting = false

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	//
	private var _bindingSelectedCert: Binding<Int>?
	private var _selectedCertBinding: Binding<Int> {
		_bindingSelectedCert ?? $_storedSelectedCert
	}
	
	init(selectedCert: Binding<Int>? = nil) {
		self._bindingSelectedCert = selectedCert
	}
	
	// MARK: Body
	var body: some View {
		VStack(spacing: 0) {
			_expiryBanner
			
			if let selected = _selectedCertificate {
				CertificateHeroCardView(cert: selected)
					.contextMenu {
						_contextActions(for: selected)
						if selected.isDefault != true {
							Divider()
							_actions(for: selected)
						}
					}

				CertificateHealthView(cert: selected)
			}

			_dnsProtectionCard
			
			Button {
				_isSelfRefreshConfirmPresenting = true
			} label: {
				Label(.localized("Refresh Zenith Itself"), image: "icon-renew")
			}
			.buttonStyle(.bordered)
			.padding(.vertical, 8)
		}
		.starfieldBackground()
		.navigationTitle(.localized("Certificates"))
		.overlay {
			if _certificates.isEmpty {
				if #available(iOS 17, *) {
					ContentUnavailableView {
						Label(.localized("No Certificates"), systemImage: "questionmark.folder.fill")
					} description: {
						Text(.localized("Get started signing by importing your first certificate."))
					} actions: {
						Button {
							_isAddingPresenting = true
						} label: {
							NBButton(.localized("Import"), style: .text)
						}
					}
				}
			}
		}
		.toolbar {
			if _bindingSelectedCert == nil {
				NBToolbarButton(
					image: "icon-resign",
					style: .icon,
					placement: .topBarTrailing,
					isDisabled: _isRefreshing
				) {
					Task {
						_isRefreshing = true
						_refreshReport = await AutoRefreshManager.shared.refreshDueApps()
						_isRefreshing = false
						_isRefreshResultPresenting = true
					}
				}
				NBToolbarButton(
					systemImage: "plus",
					style: .icon,
					placement: .topBarTrailing
				) {
					_isAddingPresenting = true
				}
			}
		}
		.sheet(item: $_isSelectedInfoPresenting) { cert in
			CertificatesInfoView(cert: cert)
				.zenithSheetBackground()
		}
		.sheet(isPresented: $_isAddingPresenting) {
			CertificatesAddView()
				.presentationDetents([.medium])
				.zenithSheetBackground()
		}
		.alert(.localized("Change Nickname"), isPresented: $_isRenamingPresenting, presenting: _certToRename) { cert in
			TextField(.localized("Nickname"), text: $_newNickname)
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("OK")) {
				cert.nickname = _newNickname.isEmpty ? nil : _newNickname
				Storage.shared.saveContext()
				// Zenith v2.2: the widget shows the nickname.
				WidgetDataStore.shared.sync()
			}
		}
		.alert(.localized("Refresh"), isPresented: $_isRefreshResultPresenting) {
			Button(.localized("OK"), role: .cancel) { }
		} message: {
			Text(_refreshResultMessage)
		}
		.alert(.localized("Refresh Zenith Itself"), isPresented: $_isSelfRefreshConfirmPresenting) {
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("Refresh"), role: .destructive) {
				Task {
					do {
						switch try await AutoRefreshManager.shared.refreshSelf() {
						case .installed:
							_selfRefreshResult = .localized("Zenith was re-signed and installed over itself.")
						case .ipaReady:
							_selfRefreshResult = .localized("A freshly signed Zenith IPA was saved to Archives. Install it with SideStore or ESign.")
						case .notAttempted:
							_selfRefreshResult = .localized("Self-refresh was not attempted.")
						}
					} catch {
						_selfRefreshResult = error.localizedDescription
					}
					_isSelfRefreshResultPresenting = true
				}
			}
		} message: {
			Text(.localized("This re-signs Zenith itself and installs the new copy over this one. If the certificate came from Apple, a fresh one is fetched first; otherwise the current certificate is used. If anything fails, the old copy keeps running."))
		}
		.alert(.localized("Refresh Zenith Itself"), isPresented: $_isSelfRefreshResultPresenting) {
			Button(.localized("OK"), role: .cancel) { }
		} message: {
			Text(_selfRefreshResult ?? "")
		}
		.alert(.localized("Profile Not Found"), isPresented: $_isProfileNotFoundPresenting) {
			Button(.localized("OK"), role: .cancel) { }
		} message: {
			Text(.localized("The protection profile is missing from the app. Please reinstall Zenith."))
		}
	}
	
	private var _refreshResultMessage: String {
		guard let report = _refreshReport else {
			return ""
		}
		if report.refreshedAppNames.isEmpty && report.failed.isEmpty {
			return .localized("Nothing to refresh right now.")
		}
		var parts: [String] = []
		if !report.refreshedAppNames.isEmpty {
			parts.append(.localized("Refreshed: %@", arguments: report.refreshedAppNames.joined(separator: ", ")))
			parts.append(.localized("Open the Library and install the refreshed apps."))
		}
		for failure in report.failed {
			parts.append("\(failure.name): \(failure.error.localizedDescription)")
		}
		return parts.joined(separator: "\n")
	}

	// MARK: Expiry reminder
	private var _selectedCertificate: CertificatePair? {
		let index = _selectedCertBinding.wrappedValue
		if index >= 0 && index < _certificates.count {
			return _certificates[index]
		}
		return _certificates.first
	}
	
	private var _soonestExpiring: CertificatePair? {
		_certificates
			.filter { ($0.expiration ?? .distantFuture) <= Date().addingTimeInterval(7 * 86400) }
			.min(by: { ($0.expiration ?? .distantFuture) < ($1.expiration ?? .distantFuture) })
	}
	
	@ViewBuilder
	private var _expiryBanner: some View {
		if let cert = _soonestExpiring, let expiration = cert.expiration {
			let info = expiration.expirationInfo()
			HStack(spacing: 12) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(info.color)
					.font(.title3)
				
				VStack(alignment: .leading, spacing: 2) {
					Text(.localized("Certificate expires soon"))
						.font(.headline)
					Text([cert.nickname, info.formatted].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				
				Spacer()
				
				Button(.localized("Renew Certificate")) {
					_isAddingPresenting = true
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
			}
			.padding()
			.zenithGlassCard(cornerRadius: 14, fallback: Color(uiColor: .secondarySystemFill))
			.overlay(
				RoundedRectangle(cornerRadius: 14)
					.strokeBorder(info.color, lineWidth: 1.5)
			)
			.padding(.horizontal)
			.padding(.top, 8)
		}
	}
}

// MARK: - View extension
extension CertificatesView {
	@ViewBuilder
	private var _dnsProtectionCard: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 10) {
				Image("icon-protection")
					.renderingMode(.template)
					.resizable()
					.scaledToFit()
					.frame(width: 24, height: 24)
					.foregroundStyle(Color.accentColor)
				
				Text(.localized("Anti-Revoke Protection"))
					.font(.headline)
				
				Spacer()
				
				Text(.localized(_dnsProtectionInstalled ? "Protection Installed" : "Protection Not Installed"))
					.font(.footnote)
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background(
						Capsule().fill(_dnsProtectionInstalled ? Color.green.opacity(0.2) : Color(uiColor: .secondarySystemFill))
					)
					.foregroundStyle(_dnsProtectionInstalled ? .green : .secondary)
			}
			
			Text(.localized("Blocks Apple's revocation checks so signed apps keep opening if the certificate is revoked."))
				.font(.footnote)
				.foregroundStyle(.secondary)
			
			Button {
				_installDNSProtection()
			} label: {
				Label(.localized(_dnsProtectionInstalled ? "Reinstall Protection" : "Install Protection"), image: "icon-protection")
			}
			.buttonStyle(.borderedProminent)
			
			Text(.localized("iOS does not let the app verify installation. This status is based on your install tap."))
				.font(.caption2)
				.foregroundStyle(.secondary)
			
			if _dnsProtectionInstalled {
				Text(.localized("To remove the protection: Settings → VPN & Device Management."))
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
		}
		.padding()
		.zenithGlassCard(cornerRadius: 18, fallback: Color(uiColor: .secondarySystemFill))
		.padding(.horizontal)
		.padding(.top, 8)
	}
	
	/// Opens the bundled anti-revoke profile so iOS can install it.
	/// The user confirms once in Settings. The install tap is recorded
	/// locally because iOS gives the app no API to verify that a
	/// specific profile is installed.
	private func _installDNSProtection() {
		guard let bundleURL = Bundle.main.url(forResource: "ZenithAntiRevoke", withExtension: "mobileconfig") else {
			_isProfileNotFoundPresenting = true
			return
		}
		let tempURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("ZenithAntiRevoke.mobileconfig")
		try? FileManager.default.removeItem(at: tempURL)
		guard (try? FileManager.default.copyItem(at: bundleURL, to: tempURL)) != nil else {
			_isProfileNotFoundPresenting = true
			return
		}
		UIApplication.shared.open(tempURL) { success in
			if success {
				// Record the tap in UserDefaults directly: the open
				// completion runs outside the view struct, and the
				// @AppStorage wrapper observes the same keys.
				UserDefaults.standard.set(true, forKey: "Zenith.dnsProtectionInstalled")
			} else {
				// iOS would not open the profile directly: offer the
				// share sheet so the user can open it in Safari/Files.
				Task { @MainActor in
					UIActivityViewController.show(activityItems: [tempURL])
				}
			}
		}
	}
	
	@ViewBuilder
	private func _actions(for cert: CertificatePair) -> some View {
		Button(role: .destructive) {
			Storage.shared.deleteCertificate(for: cert)
		} label: {
			Label(.localized("Delete"), image: "icon-delete")
		}
	}
	
	@ViewBuilder
	private func _contextActions(for cert: CertificatePair) -> some View {
		Button {
			_isSelectedInfoPresenting = cert
		} label: {
			Label(.localized("Get Info"), image: "icon-info")
		}
		Button(.localized("Change Nickname"), systemImage: "pencil") {
			_newNickname = cert.nickname ?? ""
			_certToRename = cert
			_isRenamingPresenting = true
		}
		Button {
			_isAddingPresenting = true
		} label: {
			Label(.localized("Renew Certificate"), image: "icon-resign")
		}
		Divider()
		Button(.localized("Check Revokage"), systemImage: "person.text.rectangle") {
			Storage.shared.revokagedCertificate(for: cert)
		}
	}
}
