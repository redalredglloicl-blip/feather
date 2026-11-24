//
//  CertificatesView.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
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
			
			NBGrid {
				ForEach(Array(_certificates.enumerated()), id: \.element.uuid) { index, cert in
					_cellButton(for: cert, at: index)
				}
			}
			
			Button {
				_isSelfRefreshConfirmPresenting = true
			} label: {
				Label(.localized("Refresh Feather Itself"), systemImage: "arrow.clockwise.circle")
			}
			.buttonStyle(.bordered)
			.padding(.vertical, 8)
		}
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
					systemImage: "arrow.clockwise",
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
		}
		.sheet(isPresented: $_isAddingPresenting) {
			CertificatesAddView()
				.presentationDetents([.medium])
		}
		.alert(.localized("Change Nickname"), isPresented: $_isRenamingPresenting, presenting: _certToRename) { cert in
			TextField(.localized("Nickname"), text: $_newNickname)
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("OK")) {
				cert.nickname = _newNickname.isEmpty ? nil : _newNickname
				Storage.shared.saveContext()
			}
		}
		.alert(.localized("Refresh"), isPresented: $_isRefreshResultPresenting) {
			Button(.localized("OK"), role: .cancel) { }
		} message: {
			Text(_refreshResultMessage)
		}
		.alert(.localized("Refresh Feather Itself"), isPresented: $_isSelfRefreshConfirmPresenting) {
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("Refresh"), role: .destructive) {
				Task {
					do {
						switch try await AutoRefreshManager.shared.refreshSelf() {
						case .installed:
							_selfRefreshResult = .localized("Feather was re-signed and installed over itself.")
						case .ipaReady:
							_selfRefreshResult = .localized("A freshly signed Feather IPA was saved to Archives. Install it with SideStore or ESign.")
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
			Text(.localized("This re-signs Feather itself with a fresh free certificate and installs the new copy over this one. If anything fails, the old copy keeps running."))
		}
		.alert(.localized("Refresh Feather Itself"), isPresented: $_isSelfRefreshResultPresenting) {
			Button(.localized("OK"), role: .cancel) { }
		} message: {
			Text(_selfRefreshResult ?? "")
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
}


	// MARK: Expiry reminder
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
					Text([cert.nickname, info.formatted].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u00b7 "))
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
			.background(
				RoundedRectangle(cornerRadius: 14)
					.fill(Color(uiColor: .secondarySystemFill))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 14)
					.strokeBorder(info.color, lineWidth: 1.5)
			)
			.padding(.horizontal)
			.padding(.top, 8)
		}
	}
	
// MARK: - View extension
extension CertificatesView {
	@ViewBuilder
	private func _cellButton(for cert: CertificatePair, at index: Int) -> some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		Button {
			_selectedCertBinding.wrappedValue = index
		} label: {
			CertificatesCellView(
				cert: cert
			)
			.padding()
			.background(
				RoundedRectangle(cornerRadius: cornerRadius)
					.fill(Color(uiColor: .quaternarySystemFill))
			)
			.overlay(
				RoundedRectangle(cornerRadius: cornerRadius)
					.strokeBorder(
						_selectedCertBinding.wrappedValue == index ? Color.accentColor : Color.clear,
						lineWidth: 2
					)
			)
			.contextMenu {
				_contextActions(for: cert)
				if cert.isDefault != true {
					Divider()
					_actions(for: cert)
				}
			}
			.transaction {
				$0.animation = nil
			}
		}
		.buttonStyle(.plain)
	}
	
	@ViewBuilder
	private func _actions(for cert: CertificatePair) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			Storage.shared.deleteCertificate(for: cert)
		}
	}
	
	@ViewBuilder
	private func _contextActions(for cert: CertificatePair) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			_isSelectedInfoPresenting = cert
		}
		Button(.localized("Change Nickname"), systemImage: "pencil") {
			_newNickname = cert.nickname ?? ""
			_certToRename = cert
			_isRenamingPresenting = true
		}
		Button(.localized("Renew Certificate"), systemImage: "arrow.clockwise") {
			_isAddingPresenting = true
		}
		Divider()
		Button(.localized("Check Revokage"), systemImage: "person.text.rectangle") {
			Storage.shared.revokagedCertificate(for: cert)
		}
	}
}
