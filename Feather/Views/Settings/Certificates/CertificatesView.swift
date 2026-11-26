//
//  CertificatesView.swift
//  Zenith
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
import UIKit
import NimbleViews

// MARK: - View
struct CertificatesView: View {
	@AppStorage("zenith.selectedCert") private var _storedSelectedCert: Int = 0
	
	@State private var _isAddingPresenting = false
	@State private var _isDirectDownloadPresenting = false
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
	@State private var _dnsProfileURL: URL?
	@State private var _isDNSDocumentPresenterPresented = false

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
	
	// The whole tab is ONE scrolling column: expiry banner, selected
	// certificate hero + health, DNS protection card, refresh button,
	// and — when there are no certificates — the empty state as a
	// normal in-flow section. Nothing here is an overlay, so no card
	// can ever sit on top of another view's text or button.
	var body: some View {
		ScrollView {
			VStack(spacing: 8) {
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
				
				if _certificates.isEmpty {
					_emptyState
				}
				
				_dnsProtectionCard
				
				Button {
					_isSelfRefreshConfirmPresenting = true
				} label: {
					// Sized icon: a bare Label image renders the
					// 96px PNG at full size (the v2.3 giant-icon bug).
					HStack(spacing: 8) {
						Image("icon-renew")
							.resizable()
							.scaledToFit()
							.frame(width: 20, height: 20)
						Text(.localized("Refresh Zenith Itself"))
					}
				}
				.buttonStyle(.bordered)
				.padding(.vertical, 8)
				
				Button {
					_isDirectDownloadPresenting = true
				} label: {
					HStack(spacing: 8) {
						Image("icon-download")
							.resizable()
							.scaledToFit()
							.frame(width: 20, height: 20)
						Text(.localized("تحميل شهادة من رابط"))
					}
				}
				.buttonStyle(.bordered)
				.padding(.vertical, 8)
			}
		}
		.starfieldBackground()
		.navigationTitle(.localized("Certificates"))
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
		.sheet(isPresented: $_isDirectDownloadPresenting) {
			CertificateDirectDownloadView()
				.zenithSheetBackground()
		}
		.sheet(isPresented: $_isDNSDocumentPresenterPresented) {
			if let url = _dnsProfileURL {
				_DNSProfileDocumentView(url: url) { presented in
					_isDNSDocumentPresenterPresented = false
					if presented {
						// iOS offered an open route for the profile:
						// record the tap. iOS still gives the app no
						// way to confirm the profile really installed.
						_dnsProtectionInstalled = true
					} else if let url = _dnsProfileURL {
						// No app offered to open the profile: fall back
						// to the share sheet so the user can send it to
						// Safari or Files themselves.
						Task { @MainActor in
							UIActivityViewController.show(activityItems: [url])
						}
					}
				}
			}
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
	/// Empty state, in the normal flow of the column — never an
	/// overlay, so its icon and text cannot collide with the DNS card
	/// or any other view.
	@ViewBuilder
	private var _emptyState: some View {
		VStack(spacing: 12) {
			// Real certificate icon, not the grey "?" placeholder.
			Image("icon-certificates")
				.resizable()
				.scaledToFit()
				.frame(width: 48, height: 48)
			
			Text(.localized("No Certificates"))
				.font(.headline)
			
			Text(.localized("Get started signing by importing your first certificate."))
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			
			Button {
				_isAddingPresenting = true
			} label: {
				NBButton(.localized("Import"), style: .text)
			}
			
			Button {
				_isDirectDownloadPresenting = true
			} label: {
				NBButton(.localized("تحميل شهادة من رابط"), style: .text)
			}
		}
		.padding()
		.frame(maxWidth: .infinity)
		.zenithGlassCard(cornerRadius: 18)
	}
	
	/// Hosted copy of the protection profile, served by the Cloudflare
	/// Worker in `zenith-dns-profile-worker.js` (repo root).
	/// nil until the worker is deployed — the Safari button stays
	/// hidden so it can never open a dead link. Set to the real
	/// deployed worker URL when it exists.
	private static let _dnsProfileHostedURL: String? = nil
	
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
				// Sized icon: a bare Label image renders the 96px
				// PNG at full size (the v2.3 giant-icon bug).
				HStack(spacing: 8) {
					Image("icon-protection")
						.resizable()
						.scaledToFit()
						.frame(width: 20, height: 20)
					Text(.localized(_dnsProtectionInstalled ? "Reinstall Protection" : "Install Protection"))
				}
			}
			.buttonStyle(.borderedProminent)
			
			// Second route, shown only once the hosted worker URL is
			// set: Safari opens the hosted copy, and iOS offers the
			// profile install from there. Use it whenever the first
			// button does not produce an install prompt.
			if Self._dnsProfileHostedURL != nil {
				Button {
					_installDNSProtectionViaSafari()
				} label: {
					Label(.localized("ثبّتها من سفاري"), systemImage: "safari")
				}
				.buttonStyle(.bordered)
				
				Text(.localized("بعد ما ينفتح الملف، كمّل التثبيت من الإعدادات: ملف تعريفي تم تنزيله."))
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
			
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
	
	/// PRIMARY route: copy the bundled profile to a temp file and hand
	/// it to UIDocumentInteractionController (via the sheet below), so
	/// iOS offers the system route for opening a configuration
	/// profile. `UIApplication.open` on a local .mobileconfig does
	/// nothing visible — that was the old, broken behaviour.
	/// The install tap is recorded locally because iOS gives the app
	/// no API to verify that a specific profile is installed.
	private func _installDNSProtection() {
		guard let tempURL = _dnsProfileTempURL() else {
			_isProfileNotFoundPresenting = true
			return
		}
		_dnsProfileURL = tempURL
		_isDNSDocumentPresenterPresented = true
	}
	
	/// FALLBACK route: open the hosted copy in Safari, where iOS
	/// offers the profile install from the download. Same honest
	/// basis as the primary route: the tap is recorded, installation
	/// itself cannot be verified by the app.
	private func _installDNSProtectionViaSafari() {
		guard let hosted = Self._dnsProfileHostedURL, let url = URL(string: hosted) else {
			return
		}
		UIApplication.shared.open(url)
		_dnsProtectionInstalled = true
	}
	
	/// Copies the bundled profile to a temp file for handing to the
	/// system. Returns nil when the bundled profile is missing.
	private func _dnsProfileTempURL() -> URL? {
		guard let bundleURL = Bundle.main.url(forResource: "ZenithAntiRevoke", withExtension: "mobileconfig") else {
			return nil
		}
		let tempURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("ZenithAntiRevoke.mobileconfig")
		try? FileManager.default.removeItem(at: tempURL)
		guard (try? FileManager.default.copyItem(at: bundleURL, to: tempURL)) != nil else {
			return nil
		}
		return tempURL
	}
	
	@ViewBuilder
	private func _actions(for cert: CertificatePair) -> some View {
		Button(role: .destructive) {
			Storage.shared.deleteCertificate(for: cert)
		} label: {
			Label {
				Text(.localized("Delete"))
			} icon: {
				Image("icon-delete")
					.resizable()
					.scaledToFit()
					.frame(width: 20, height: 20)
			}
		}
	}
	
	@ViewBuilder
	private func _contextActions(for cert: CertificatePair) -> some View {
		Button {
			_isSelectedInfoPresenting = cert
		} label: {
			Label {
				Text(.localized("Get Info"))
			} icon: {
				Image("icon-info")
					.resizable()
					.scaledToFit()
					.frame(width: 20, height: 20)
			}
		}
		Button(.localized("Change Nickname"), systemImage: "pencil") {
			_newNickname = cert.nickname ?? ""
			_certToRename = cert
			_isRenamingPresenting = true
		}
		Button {
			_isAddingPresenting = true
		} label: {
			Label {
				Text(.localized("Renew Certificate"))
			} icon: {
				Image("icon-resign")
					.resizable()
					.scaledToFit()
					.frame(width: 20, height: 20)
			}
		}
		Divider()
		Button(.localized("Check Revokage"), systemImage: "person.text.rectangle") {
			Storage.shared.revokagedCertificate(for: cert)
		}
	}
}

// MARK: - DNS profile document interaction
//
// Presents the bundled .mobileconfig with UIDocumentInteractionController
// so iOS offers the system route for opening a configuration profile.
// The interaction controller needs a view controller to present from,
// so it lives in a sheet-hosted view controller that presents the
// "Open In" menu (QuickLook preview as a second try) as soon as it
// appears, then reports back and closes the sheet.

private struct _DNSProfileDocumentView: UIViewControllerRepresentable {
	let url: URL
	/// Called on the main thread when the menu/preview closes.
	/// `presented` is true when iOS actually offered an open route.
	let onFinished: (Bool) -> Void
	
	func makeUIViewController(context: Context) -> _DNSProfileDocumentViewController {
		_DNSProfileDocumentViewController(url: url, onFinished: onFinished)
	}
	
	func updateUIViewController(_ uiViewController: _DNSProfileDocumentViewController, context: Context) {}
}

private final class _DNSProfileDocumentViewController: UIViewController, UIDocumentInteractionControllerDelegate {
	private let _url: URL
	private let _onFinished: (Bool) -> Void
	private var _interactionController: UIDocumentInteractionController?
	private var _didPresent = false
	private var _didFinish = false
	
	init(url: URL, onFinished: @escaping (Bool) -> Void) {
		self._url = url
		self._onFinished = onFinished
		super.init(nibName: nil, bundle: nil)
	}
	
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
	
	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		guard !_didPresent else {
			return
		}
		_didPresent = true
		
		let controller = UIDocumentInteractionController(url: _url)
		controller.delegate = self
		// Retained: the interaction controller must stay alive while
		// its menu or preview is on screen.
		_interactionController = controller
		
		// "Open In" menu first: it lists the apps that can take the
		// profile. QuickLook preview as a second try. If neither can
		// be shown, report failure so the caller can fall back to the
		// share sheet.
		if controller.presentOpenInMenu(from: view.bounds, in: view, animated: true) {
			return
		}
		if controller.presentPreview(animated: true) {
			return
		}
		_finish(presented: false)
	}
	
	// MARK: UIDocumentInteractionControllerDelegate
	
	func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
		self
	}
	
	func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
		_finish(presented: true)
	}
	
	func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
		_finish(presented: true)
	}
	
	private func _finish(presented: Bool) {
		guard !_didFinish else {
			return
		}
		_didFinish = true
		DispatchQueue.main.async { [onFinished = _onFinished] in
			onFinished(presented)
		}
	}
}
