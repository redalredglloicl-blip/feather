//
//  SigningView.swift
//  Zenith
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import PhotosUI
import NimbleViews

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isSigning = false
	@State private var _isSuccessPresenting = false
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	/// iOS-compat warning shown before signing starts (set by _start).
	@State private var _isCompatAlertPresenting = false
	@State private var _compatMinimumOS = ""
	@State private var _compatDeviceOS = ""
	@State var appIcon: UIImage?
	/// Zenith v2.12: text of the custom display-name field (owned
	/// here so Reset can restore the real name).
	@State private var _displayNameText: String = ""
	/// Zenith v2.12: shared moddability verdict for the signing
	/// screen's modding sections (filled by the check, read by the
	/// edit / mod-menu / graphics / FPS tools to gate themselves).
	@State private var _moddabilityReport: ModdabilityReport?
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable) {
		self.app = app
		let storedCert = UserDefaults.standard.integer(forKey: "zenith.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	// MARK: - Extracted subviews (kept separate so the compiler
	// can type-check `body` in reasonable time).
	private var _bottomBar: some View {
		VStack(spacing: 0) {
			Spacer()
			NBVariableBlurView()
				.frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 60 : 80)
				.rotationEffect(.degrees(180))
				.overlay {
					Button {
						_start()
					} label: {
						NBSheetButton(title: .localized("Start Signing"), style: .prominent)
							.padding()
					}
					.buttonStyle(ZenithPressButtonStyle())
					.offset(y: UIDevice.current.userInterfaceIdiom == .pad ? -20 : -40)
				}
		}
		.ignoresSafeArea(edges: .bottom)
	}

	@ViewBuilder
	private var _successOverlay: some View {
		if _isSuccessPresenting {
			SigningSuccessView(appName: app.name ?? .localized("Unknown")) {
				withAnimation(.easeOut(duration: 0.25)) {
					_isSuccessPresenting = false
				}
				if _temporaryOptions.post_installAppAfterSigned {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
						NotificationCenter.default.post(name: Notification.Name("Zenith.installApp"), object: nil)
					}
				}
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
					dismiss()
				}
			}
			.transition(.opacity.combined(with: .scale(scale: 0.95)))
		}
	}

	// MARK: Body
	var body: some View {
		NBNavigationView("", displayMode: .inline) {
			Form {
				_customizationOptions(for: app)
				_cert()
				_sharedModdingTools(for: app)
				_moddingSectionGames(for: app)
				_moddingSectionApps(for: app)
				_customizationProperties(for: app)
				
				// horrible
				Rectangle()
					.foregroundStyle(.clear)
					.frame(height: 30)
					.listRowBackground(EmptyView())
			}
			// Zenith v2.8: stars on every pushed sub-screen — the
			// starfield sits behind this form, same as the tab roots.
			.scrollContentBackground(.hidden)
			.background(Color.clear)
			.starfieldBackground()
			.listRowBackground(Color.clear)
			.overlay { _bottomBar }

			.toolbar {
				NBToolbarButton(role: .dismiss)
				ToolbarItem(placement: .principal) {
					Image("zenith-transparent")
						.resizable()
						.scaledToFit()
						.frame(height: 38)
				}
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					_temporaryOptions = OptionsManager.shared.options
					appIcon = nil
					// Zenith v2.12: Reset also forgets the remembered
					// custom name for this app and clears the shared
					// moddability verdict.
					if let realName = app.name {
						_optionsManager.options.displayNames.removeValue(forKey: realName)
					}
					_displayNameText = app.name ?? ""
					_moddabilityReport = nil
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)).zenithSheetBackground() }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
				.ignoresSafeArea()
				.zenithSheetBackground()
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				
				Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}
			.disabled(_isSigning)
			.animation(.smooth, value: _isSigning)

		}
		.alert(.localized("هالتطبيق يحتاج iOS أحدث"), isPresented: $_isCompatAlertPresenting) {
			Button(.localized("إلغاء"), role: .cancel) { }
			Button(.localized("وقّع على أي حال")) {
				_start(confirmed: true)
			}
		} message: {
			Text(verbatim: .localized("هالتطبيق يحتاج iOS %@ على الأقل، وجهازك عليه iOS %@. ممكن ما يشتغل بعد التوقيع.", arguments: _compatMinimumOS, _compatDeviceOS))
		}
		.overlay { _successOverlay }
		.onAppear {
			// ppq protection
			if
				_optionsManager.options.ppqProtection,
				let identifier = app.identifier,
				let cert = _selectedCert(),
				cert.ppQCheck
			{
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}
			
			if
				let currentBundleId = app.identifier,
				let newBundleId = _temporaryOptions.identifiers[currentBundleId]
			{
				_temporaryOptions.appIdentifier = newBundleId
			}
			
			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}

			// Zenith v2.12, item 2: the custom-name field's text.
			_displayNameText = _temporaryOptions.appName ?? app.name ?? ""
		}
	}
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Customization")) {
			Menu {
				Button(.localized("Select Alternative Icon"), systemImage: "app.dashed") { _isAltPickerPresenting = true }
				Button(.localized("Choose from Files"), systemImage: "folder") { _isFilePickerPresenting = true }
				Button(.localized("Choose from Photos"), systemImage: "photo") { _isImagePickerPresenting = true }
			} label: {
				if let icon = appIcon {
					Image(uiImage: icon)
						.appIconStyle()
				} else {
					ZenithAppIconView(app: app, size: 56)
				}
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
			
			// Zenith v2.12, item 2 (#3): custom display name — the
			// field itself syncs the typed name into the temporary
			// options and remembers it per app (replaces the plain
			// Name editor above it: same job, plus remembering).
			CustomDisplayNameField(
				app: app,
				displayNameText: $_displayNameText,
				temporaryOptions: $_temporaryOptions
			)
			_infoCell(.localized("Identifier"), desc: _temporaryOptions.appIdentifier ?? app.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					bindingValue: $_temporaryOptions.appIdentifier
				)
			}
			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion
				)
			}
		}
	}
	
	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(
						cert: cert
					)
				}
			} else {
				Text(.localized("No Certificate"))
					.font(.footnote)
					.foregroundColor(.disabled())
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			}
		}
	}
	
	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Advanced")) {
			DisclosureGroup(.localized("Modify")) {
				NavigationLink(.localized("Existing Dylibs")) {
					SigningDylibView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				.zenithGlassCard(cornerRadius: 12)
				.padding(.vertical, 6)
				.listRowSeparator(.hidden)
				
				NavigationLink(.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				.zenithGlassCard(cornerRadius: 12)
				.padding(.vertical, 6)
				.listRowSeparator(.hidden)
			
				NavigationLink(.localized("Entitlements") + " (BETA)") {
					SigningEntitlementsView(
						bindingValue: $_temporaryOptions.appEntitlementsFile
					)
				}
				.zenithGlassCard(cornerRadius: 12)
				.padding(.vertical, 6)
				.listRowSeparator(.hidden)
				
				NavigationLink(.localized("Tweaks")) {
					SigningTweaksView(
						options: $_temporaryOptions
					)
				}
				.zenithGlassCard(cornerRadius: 12)
				.padding(.vertical, 6)
				.listRowSeparator(.hidden)
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
			
			NavigationLink(.localized("Properties")) {
				Form { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options
				)}
				// Zenith v2.8: stars on this pushed screen too.
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.starfieldBackground()
				.listRowBackground(Color.clear)
				.navigationTitle(.localized("Properties"))
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
		}
	}

	// MARK: - Zenith v2.12: modding sections
	// Arrangement (Reda's order): shared tools on top, then two
	// sections — games, then apps. Every row shows its title with
	// a 1–2 line Iraqi explanation underneath it. Unpicked slots
	// are simply absent — nothing is shown for a feature Reda did
	// not pick.

	/// Shared modding tools (used by both sections): browse the
	/// IPA's files, check whether the app can be modded, and keep
	/// a copy of the original before modding.
	@ViewBuilder
	private func _sharedModdingTools(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Modding Tools")) {
			ModdingIPABrowserView(app: app)
			ModdingCheckView(app: app, report: $_moddabilityReport)
			BackupOriginalRowView(app: app)
		}
	}

	/// Section 1 — "تعديل الألعاب": game modding.
	@ViewBuilder
	private func _moddingSectionGames(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Mod Games")) {
			NavigationLink {
				ValueEditorView(options: $_temporaryOptions, report: _moddabilityReport)
			} label: {
				ValueEditorRowLabel()
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
			ModFileEditorView(app: app, options: $_temporaryOptions, report: _moddabilityReport)
			GraphicsSettingsView(app: app, options: $_temporaryOptions, report: _moddabilityReport)
			FPSCounterView(options: $_temporaryOptions, report: _moddabilityReport)
		}
	}

	/// Section 2 — "تعديل التطبيقات": app modding.
	@ViewBuilder
	private func _moddingSectionApps(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Mod Apps")) {
			_moddingRow(
				title: .localized("Remove Ads"),
				description: .localized("Remove Ads Row Description")
			) {
				RemoveAdsView(app: app, options: $_temporaryOptions)
			}
			_moddingRow(
				title: .localized("Developer Menus"),
				description: .localized("Developer Menus Row Description")
			) {
				DevMenuView(app: app, options: $_temporaryOptions)
			}
			_moddingRow(
				title: .localized("Remove Watermark"),
				description: .localized("Remove Watermark Row Description")
			) {
				RemoveWatermarkView(app: app, options: $_temporaryOptions)
			}
			_moddingRow(
				title: .localized("Remove Export Limits"),
				description: .localized("Remove Export Limits Row Description")
			) {
				RemoveExportLimitsView(app: app, options: $_temporaryOptions)
			}
			_moddingRow(
				title: .localized("Remove Subscription Screen"),
				description: .localized("Remove Subscription Screen Row Description")
			) {
				RemoveSubscriptionScreenView(app: app, options: $_temporaryOptions)
			}
			_moddingRow(
				title: .localized("Stop Forced Updates"),
				description: .localized("Stop Forced Updates Row Description")
			) {
				StopForcedUpdatesView(app: app, options: $_temporaryOptions)
			}
			_moddingRow(
				title: .localized("Change App Font"),
				description: .localized("Change App Font Row Description")
			) {
				ChangeAppFontView(app: app, options: $_temporaryOptions)
			}
			_moddingRow(
				title: .localized("Speed Up Animations"),
				description: .localized("Speed Up Animations Row Description")
			) {
				AnimationSpeedView(app: app, options: $_temporaryOptions)
			}
			NavigationLink {
				ChangeLocationView(app: app, options: $_temporaryOptions)
			} label: {
				ChangeLocationRowLabel()
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
			NavigationLink {
				GuestModeView(app: app, options: $_temporaryOptions)
			} label: {
				GuestModeRowLabel()
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
			NavigationLink {
				ForceDarkModeView(app: app, options: $_temporaryOptions)
			} label: {
				ForceDarkModeRowLabel()
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
			InAppTranslationRowView(app: app, options: $_temporaryOptions)
			LiteVersionRowView(app: app, options: $_temporaryOptions)
		}
	}

	/// A modding row: title on top, 1–2 line Iraqi explanation
	/// underneath it, in the row itself (Reda's standing rule).
	@ViewBuilder
	private func _moddingRow<V: View>(title: String, description: String, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
				Text(verbatim: description)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
		}
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
	}

	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
			}
		}
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
	}
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start(confirmed: Bool = false) {
		// Zenith v2.2: warn when the IPA needs a newer iOS than this
		// device runs. The user can still proceed — the warning is
		// advice, not a block.
		if !confirmed {
			switch IOSCompatValidator.check(app: app) {
			case .requiresNewer(let minimumOS, let deviceOS):
				_compatMinimumOS = minimumOS
				_compatDeviceOS = deviceOS
				_isCompatAlertPresenting = true
				return
			case .compatible, .unknown:
				break
			}
		}

		guard
			_selectedCert() != nil || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()
		_isSigning = true
		
		Zenith.signPackageFile(
			app,
			using: _temporaryOptions,
			icon: appIcon,
			certificate: _selectedCert()
		) { error in
			if let error {
				let ok = UIAlertAction(title: .localized("Dismiss"), style: .cancel) { _ in
					dismiss()
				}
				
				UIAlertController.showAlert(
					title: "Error",
					message: error.localizedDescription,
					actions: [ok]
				)
			} else {
				// Zenith v2.2: keep the custom icon picked in this
				// sheet for the app's Library icon, keyed by the
				// bundle identifier the app was signed with.
				if let icon = appIcon {
					CustomAppIconStore.shared.save(icon, for: _temporaryOptions.appIdentifier ?? app.identifier)
				}
				ZenithLastError.clear()

				if
					_temporaryOptions.post_deleteAppAfterSigned,
					!app.isSigned
				{
					Storage.shared.deleteApp(for: app)
				}

				// Zenith: show the animated success screen instead of
				// dismissing silently. The install-after-sign trigger
				// moves to the success screen's dismiss button, so the
				// install sheet never pops up under the success view.
				_isSigning = false
				withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
					_isSuccessPresenting = true
				}
			}
		}
	}
}
