//
//  LibraryAppIconView.swift
//  Zenith
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// MARK: - View
struct LibraryCellView: View {
	@Environment(\.editMode) private var editMode
	@ObservedObject private var _prefs = LibraryPrefs.shared
	/// Zenith 2.34 (Store): observes the store manager so the
	/// "تحديث" pill below appears once the feeds load.
	@ObservedObject private var _store = ZenithStoreManager.shared

	var certInfo: Date.ExpirationInfo? {
		Storage.shared.getCertificate(from: app)?.expiration?.expirationInfo()
	}
	
	var certRevoked: Bool {
		Storage.shared.getCertificate(from: app)?.revoked == true
	}
	
	var app: AppInfoPresentable
	@Binding var selectedInfoAppPresenting: AnyApp?
	@Binding var selectedSigningAppPresenting: AnyApp?
	@Binding var selectedInstallAppPresenting: AnyApp?
	/// Opens the app passport (detail screen) on a plain row tap.
	@Binding var selectedPassportAppPresenting: AnyApp?
	@Binding var selectedAppUUIDs: Set<String>
	/// Called when the user asks to delete an app (swipe or menu).
	/// The confirmation alert lives on the Library list, not on the
	/// row: an alert owned by a row that is about to be deleted
	/// dismisses itself when the row goes away.
	var onDeleteRequest: ((AppInfoPresentable) -> Void)?

	/// Zenith v2.38 Part B: Value Editor injection runs from the
	/// long-press menu. While it runs the row shows a spinner;
	/// when it finishes (success or failure) the alert below
	/// says what happened in Iraqi.
	@State private var _isAddingValueEditor = false
	@State private var _valueEditorResultMessage: String?
	@State private var _isValueEditorResultPresenting = false

	// MARK: Selections
	private var _isSelected: Bool {
		guard let uuid = app.uuid else { return false }
		return selectedAppUUIDs.contains(uuid)
	}
	
	private func _toggleSelection() {
		guard let uuid = app.uuid else { return }
		if selectedAppUUIDs.contains(uuid) {
			selectedAppUUIDs.remove(uuid)
		} else {
			selectedAppUUIDs.insert(uuid)
		}
	}
	
	// MARK: Body
	/// Zenith v2.13: 2.0 REVERT — the Library is a compact plain
	/// list again, not a grid of large cards. The v2.3 card (icon
	/// + spacer + pill on top, name/version/last-opened below)
	/// left the whole left ~60% of every card empty black space
	/// (Reda's 2026-11-27 screenshot: "عباره عن فراغ بلا فائدة").
	/// This row fills the width with real data instead: icon,
	/// name, version + date added, bundle identifier, last opened
	/// — plus the certificate days / Sign pill at the far end, as
	/// before. File size stays on the passport (tap the row):
	/// measuring every row's directory size on appear would walk
	/// the whole .app bundle per row. No card, no capsule: a plain
	/// list row with a hairline separator, like the old 2.0
	/// Library. Install / Sign / Re-sign / Export / Open live in
	/// the long-press menu; the days pill itself is also the
	/// Install button for signed apps, and the Sign pill for
	/// imported ones.
	var body: some View {
		let isEditing = editMode?.wrappedValue == .active
		
		HStack(spacing: 12) {
			ZStack(alignment: .topLeading) {
				_appIcon(for: app)
				
				if isEditing {
					Button {
						_toggleSelection()
					} label: {
						Image(systemName: _isSelected ? "checkmark.circle.fill" : "circle")
							.font(.title2)
							.foregroundStyle(_isSelected ? Color.accentColor : .secondary)
							.background(Color(uiColor: .systemBackground), in: Circle())
					}
					.buttonStyle(.borderless)
					.offset(x: -6, y: -6)
				}
			}
			
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 4) {
					if _prefs.isFavorite(uuid: app.uuid) {
						Image(systemName: "heart.fill")
							.font(.system(size: 12, weight: .bold))
							.foregroundStyle(Color.accentColor)
					}
					Text(app.name ?? .localized("Unknown"))
						.font(.headline)
						.lineLimit(1)
				}
				HStack(spacing: 6) {
					Text(_versionAndDateText)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(1)
					// Zenith 2.34 (Store): peach "تحديث" pill next to
					// the version, only when the store feed has a
					// newer version of this app. Tapping it downloads
					// the update; nothing else about the row changes.
					if let id = app.identifier, let updateApp = _store.update(for: id, installedVersion: app.version) {
						Button {
							_store.download(updateApp)
						} label: {
							Text("تحديث")
								.font(.caption.bold())
								.foregroundStyle(.black)
								.padding(.horizontal, 8)
								.padding(.vertical, 3)
								.background(Color(hex: "#FFC778"), in: Capsule())
						}
						.buttonStyle(.borderless)
					}
				}
				if let identifier = app.identifier {
					Text(identifier)
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				Text(_lastOpenedText)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			
			Spacer()
			
			_daysPill
				.disabled(isEditing)
		}
		.overlay {
			// Selection ring only, shown in edit mode on a selected
			// row — the always-on accent rim is gone (v2.10).
			if _isSelected && isEditing {
				RoundedRectangle(cornerRadius: 12, style: .continuous)
					.strokeBorder(Color.accentColor, lineWidth: 2)
			}
		}
		.contentShape(Rectangle())
		.onTapGesture {
			if isEditing {
				_toggleSelection()
			} else {
				selectedPassportAppPresenting = AnyApp(base: app)
			}
		}
		.contextMenu {
			if !isEditing {
				_contextActions(for: app)
				Divider()
				_contextActionsExtra(for: app)
				Divider()
				_actions(for: app)
			}
		}
		.overlay(alignment: .center) {
			if _isAddingValueEditor {
				ProgressView()
					.padding(12)
					.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
			}
		}
		.alert(.localized("Value Editor"), isPresented: $_isValueEditorResultPresenting) {
			Button(.localized("OK"), role: .cancel) { }
		} message: {
			if let message = _valueEditorResultMessage {
				Text(verbatim: message)
			}
		}
	}
	
	/// Version + date added on one line ("v1.33.0 • 27 Nov 2026"):
	/// both real, both already on the record — no disk reads.
	private var _versionAndDateText: String {
		var parts: [String] = [_versionText]
		if let date = app.date {
			parts.append(Self._expiryDateFormatter.string(from: date))
		}
		return parts.joined(separator: " • ")
	}
	
	private static let _expiryDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .none
		return formatter
	}()
	
	private var _versionText: String {
		if let version = app.version {
			return "v\(version)"
		}
		return .localized("Unknown")
	}
	
	private var _lastOpenedText: String {
		if let uuid = app.uuid, let lastOpened = _prefs.lastOpenedDate(for: uuid) {
			return "\(String.localized("Last opened")): \(Self._expiryDateFormatter.string(from: lastOpened))"
		}
		return .localized("Never opened")
	}
	
	/// Compact days-remaining pill ("311d") at the far end of the row.
	/// Signed apps only — imported apps have no certificate expiry,
	/// so they get a Sign pill instead. The colour is the honest
	/// expiry colour (green while healthy, yellow/orange/red as
	/// expiry nears, grey when expired, red when revoked), never
	/// forced green: a cert with 1 day left must look urgent.
	/// Tapping the pill installs (signed) or signs (imported).
	@ViewBuilder
	private var _daysPill: some View {
		if app.isSigned {
			if certRevoked {
				_pillButton(title: .localized("Revoked"), foreground: .white, background: .red) {
					selectedInstallAppPresenting = AnyApp(base: app)
				}
			} else if let expiration = Storage.shared.getCertificate(from: app)?.expiration {
				let info = expiration.expirationInfo()
				if expiration <= Date() {
					_pillButton(title: info.formatted, foreground: .white, background: .gray) {
						selectedInstallAppPresenting = AnyApp(base: app)
					}
				} else {
					let days = Int(expiration.timeIntervalSinceNow / 86400)
					_pillButton(
						title: days >= 1 ? "\(days)d" : info.formatted,
						foreground: .white,
						background: Color.expiration(days: days)
					) {
						selectedInstallAppPresenting = AnyApp(base: app)
					}
				}
			}
		} else {
			_pillButton(
				title: .localized("Sign"),
				foreground: Color.accentColor,
				background: Color(uiColor: .quaternarySystemFill)
			) {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
		}
	}
	
	private func _pillButton(
		title: String,
		foreground: Color,
		background: Color,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Text(title)
				.font(.subheadline.bold())
				.foregroundStyle(foreground)
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.background(background.opacity(0.9), in: Capsule())
		}
		.buttonStyle(.borderless)
	}
}


// MARK: - Extension: View
extension LibraryCellView {
	private func _appIcon(for app: AppInfoPresentable) -> some View {
		ZenithAppIconView(app: app, size: 64)
	}
	
	@ViewBuilder
	private func _actions(for app: AppInfoPresentable) -> some View {
		Button(role: .destructive) {
			onDeleteRequest?(app)
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
	private func _contextActions(for app: AppInfoPresentable) -> some View {
		Button {
			selectedInfoAppPresenting = AnyApp(base: app)
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
		Button {
			_prefs.toggleFavorite(uuid: app.uuid)
		} label: {
			Label {
				Text(_prefs.isFavorite(uuid: app.uuid) ? .localized("Remove from Favorites") : .localized("Add to Favorites"))
			} icon: {
				Image("icon-favorite")
					.resizable()
					.scaledToFit()
					.frame(width: 20, height: 20)
			}
		}
		Menu {
			ForEach(LibraryView.HomeCategory.allCases, id: \.self) { category in
				Button {
					_prefs.setCategory(category, for: app.uuid)
				} label: {
					HStack {
						Text(category.pickerDisplayName)
						if _prefs.category(for: app.uuid) == category {
							Image(systemName: "checkmark")
						}
					}
				}
			}
		} label: {
			Label {
				Text(.localized("Category"))
			} icon: {
				Image("icon-category")
					.resizable()
					.scaledToFit()
					.frame(width: 20, height: 20)
			}
		}
	}
	
	@ViewBuilder
	private func _contextActionsExtra(for app: AppInfoPresentable) -> some View {
		if app.isSigned {
			if let id = app.identifier {
				Button(.localized("Open"), systemImage: "app.badge.checkmark") {
					LibraryPrefs.shared.recordOpened(uuid: app.uuid)
					UIApplication.openApp(with: id)
				}
			}
			Button {
				selectedInstallAppPresenting = AnyApp(base: app)
			} label: {
				Label {
					Text(.localized("Install"))
				} icon: {
					Image("icon-install")
						.resizable()
						.scaledToFit()
						.frame(width: 20, height: 20)
				}
			}
			Button {
				selectedSigningAppPresenting = AnyApp(base: app)
			} label: {
				Label {
					Text(.localized("Re-sign"))
				} icon: {
					Image("icon-sign")
						.resizable()
						.scaledToFit()
						.frame(width: 20, height: 20)
				}
			}
			// Zenith v2.38 Part B: directly under "وقّع" — injects
			// the Value Editor into this game WITHOUT signing, so
			// it is offered for signed games too. The menu item is
			// shown for every app on purpose: games are often
			// uncategorised, so gating on the category would hide
			// it from exactly the games Reda long-presses.
			Button {
				_addValueEditor(for: app)
			} label: {
				Label {
					Text(.localized("Add Value Editor to Game"))
				} icon: {
					Image(systemName: "slider.horizontal.3")
				}
			}
			.disabled(_isAddingValueEditor)
			Button {
				selectedInstallAppPresenting = AnyApp(base: app, archive: true)
			} label: {
				Label {
					Text(.localized("Export"))
				} icon: {
					Image("icon-export")
						.resizable()
						.scaledToFit()
						.frame(width: 20, height: 20)
				}
			}
		} else {
			Button {
				selectedInstallAppPresenting = AnyApp(base: app)
			} label: {
				Label {
					Text(.localized("Install"))
				} icon: {
					Image("icon-install")
						.resizable()
						.scaledToFit()
						.frame(width: 20, height: 20)
				}
			}
			Button {
				selectedSigningAppPresenting = AnyApp(base: app)
			} label: {
				Label {
					Text(.localized("Sign"))
				} icon: {
					Image("icon-sign")
						.resizable()
						.scaledToFit()
						.frame(width: 20, height: 20)
				}
			}
			// Zenith v2.38 Part B: directly under "وقّع" — this is
			// the point of the feature: an UNSIGNED game gets the
			// Value Editor injected with no signing step at all.
			// Shown for every app (see the signed branch note):
			// uncategorised games must not lose the item.
			Button {
				_addValueEditor(for: app)
			} label: {
				Label {
					Text(.localized("Add Value Editor to Game"))
				} icon: {
					Image(systemName: "slider.horizontal.3")
				}
			}
			.disabled(_isAddingValueEditor)
		}
	}
}

// MARK: - Extension: Value Editor (Zenith v2.38 Part B)
extension LibraryCellView {
	/// Injects the Value Editor into this game WITHOUT signing
	/// and records it in LibraryPrefs, which is what puts the
	/// game in the Home section "الألعاب المضاف لها محرر القيم".
	/// The original Library entry is never modified. Runs off
	/// the main thread (copy + inject + zip); all state changes
	/// come back on the main actor.
	private func _addValueEditor(for app: AppInfoPresentable) {
		guard !_isAddingValueEditor else { return }
		guard let uuid = app.uuid else { return }
		_isAddingValueEditor = true
		Task {
			do {
				let ipaURL = try await UnsignedValueEditorInjector.inject(into: app)
				await MainActor.run {
					_prefs.recordValueEditorGame(
						uuid: uuid,
						name: app.name ?? .localized("Unknown"),
						version: app.version,
						ipaURL: ipaURL
					)
					_valueEditorResultMessage = .localized("Value Editor Added")
					_isAddingValueEditor = false
					_isValueEditorResultPresenting = true
				}
			} catch {
				await MainActor.run {
					_valueEditorResultMessage = "\(String.localized("Adding Value Editor Failed")): \(error.localizedDescription)"
					_isAddingValueEditor = false
					_isValueEditorResultPresenting = true
				}
			}
		}
	}
}
