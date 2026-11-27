//
//  CustomDisplayNameField.swift
//  Zenith
//
//  Zenith v2.12, ITEM 2 — custom display name for the signed app.
//  Lives in the main signing options (Customization area), NOT in
//  either modding section.
//
//  The name typed here is baked into the signed IPA's Info.plist
//  (CFBundleDisplayName + CFBundleName, plus every
//  *.lproj/InfoPlist.strings) and remembered per app in
//  Options.displayNames, keyed by the app's real name — so it is
//  prefilled the next time the same app is signed.
//
//  WIRING (coordinator): the signing screen owns the text state so
//  its Reset button can put the real name back:
//
//    @State private var _displayNameText: String = ""
//
//  ...and drops this view into the "التعديل" section as item 8:
//
//    CustomDisplayNameField(
//        app: app,
//        displayNameText: $_displayNameText,
//        temporaryOptions: $_temporaryOptions
//    )
//
//  Reset must also forget the remembered name for this app:
//
//    if let realName = app.name {
//        _optionsManager.options.displayNames.removeValue(forKey: realName)
//    }
//    _displayNameText = app.name ?? ""
//

import SwiftUI
import NimbleViews

// MARK: - Zenith v2.12, ITEM 2: custom display name field (item 8 of "التعديل")
/// The custom-name field for the signing screen's "التعديل" section
/// (item 8, last). Prefilled with the app's real name, or with the
/// name remembered for this app.
///
/// - `displayNameText` is owned by the signing screen (a @State
///   there) so its Reset button can restore the real name.
/// - Every edit is stored per app in the shared
///   `Options.displayNames`, keyed by the app's real name — the
///   same key the signing screen's prefill and SigningHandler read.
/// - Empty, or the same as the real name, means "keep the real
///   name": the stored entry is dropped and `appName` is left
///   unset, so the signed IPA keeps its original name.
struct CustomDisplayNameField: View {
	var app: AppInfoPresentable
	@Binding var displayNameText: String
	@Binding var temporaryOptions: Options
	
	// MARK: Body
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(.localized("App Display Name"))
				.font(.subheadline)
				.foregroundStyle(.secondary)
			TextField(app.name ?? "", text: $displayNameText)
				.textInputAutocapitalization(.none)
				.autocorrectionDisabled()
				.onChange(of: displayNameText) { _ in _syncDisplayName() }
			Text(.localized("App Display Name Hint"))
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
		.onAppear {
			_prefill()
		}
	}
	
	/// Prefill: the name already chosen for this signing pass,
	/// else the name remembered for this app, else the real name.
	/// A remembered name is also written into the temporary
	/// options, so it is what gets signed even if the signing
	/// screen's own prefill did not run.
	private func _prefill() {
		if let chosen = temporaryOptions.appName {
			displayNameText = chosen
		} else if
			let realName = app.name,
			let remembered = temporaryOptions.displayNames[realName]
		{
			displayNameText = remembered
			temporaryOptions.appName = remembered
		} else {
			displayNameText = app.name ?? ""
		}
	}
	
	/// Keeps the typed name in sync with the options used for
	/// signing AND with the per-app remembered name.
	private func _syncDisplayName() {
		let typed = displayNameText.trimmingCharacters(in: .whitespacesAndNewlines)
		let realName = app.name ?? ""
		
		if typed.isEmpty || typed == realName {
			temporaryOptions.appName = nil
			if let realName = app.name {
				OptionsManager.shared.options.displayNames.removeValue(forKey: realName)
			}
		} else {
			temporaryOptions.appName = typed
			if let realName = app.name {
				OptionsManager.shared.options.displayNames[realName] = typed
			}
		}
	}
}
