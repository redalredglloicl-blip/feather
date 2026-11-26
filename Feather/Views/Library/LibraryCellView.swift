//
//  LibraryAppIconView.swift
//  Feather
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
	/// Zenith v2.3: the Library is a 2-column grid of large glass cards
	/// (see LibraryView), so this is a card, not a list row. Big app
	/// icon top-left, days pill top-right, name + version + last-opened
	/// below — the same data the old row showed (name, version,
	/// last-opened, expiry as the days pill). The bundle identifier
	/// no longer fits on the card face; it is still in Get Info and
	/// the passport. Install / Sign / Re-sign / Export / Open live in
	/// the long-press menu (a grid has no swipe actions); the days
	/// pill itself is also the Install button for signed apps, and
	/// the Sign pill for imported ones.
	var body: some View {
		let isEditing = editMode?.wrappedValue == .active
		
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .top, spacing: 8) {
				_appIcon(for: app)
				
				Spacer()
				
				_daysPill
					.disabled(isEditing)
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
						.lineLimit(2)
				}
				Text(_versionText)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				Text(_lastOpenedText)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.zenithGlassCard(cornerRadius: 24, fallback: Color.white.opacity(0.08))
		.overlay(
			RoundedRectangle(cornerRadius: 24, style: .continuous)
				.strokeBorder(
					_isSelected && isEditing ? Color.accentColor : Color.accentColor.opacity(0.25),
					lineWidth: _isSelected && isEditing ? 2 : 1
				)
		)
		.shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
		.contentShape(Rectangle())
		.overlay(alignment: .topLeading) {
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
	
	/// Compact days-remaining pill ("311d") top-right of the card.
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
		FRAppIconView(app: app, size: 64)
	}
	
	@ViewBuilder
	private func _actions(for app: AppInfoPresentable) -> some View {
		Button(role: .destructive) {
			onDeleteRequest?(app)
		} label: {
			Label(.localized("Delete"), image: "icon-delete")
		}
	}
	
	@ViewBuilder
	private func _contextActions(for app: AppInfoPresentable) -> some View {
		Button {
			selectedInfoAppPresenting = AnyApp(base: app)
		} label: {
			Label(.localized("Get Info"), image: "icon-info")
		}
		Button {
			_prefs.toggleFavorite(uuid: app.uuid)
		} label: {
			Label(
				_prefs.isFavorite(uuid: app.uuid) ? .localized("Remove from Favorites") : .localized("Add to Favorites"),
				image: "icon-favorite"
			)
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
			Label(.localized("Category"), image: "icon-category")
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
				Label(.localized("Install"), image: "icon-install")
			}
			Button {
				selectedSigningAppPresenting = AnyApp(base: app)
			} label: {
				Label(.localized("Re-sign"), image: "icon-sign")
			}
			Button {
				selectedInstallAppPresenting = AnyApp(base: app, archive: true)
			} label: {
				Label(.localized("Export"), image: "icon-export")
			}
		} else {
			Button {
				selectedInstallAppPresenting = AnyApp(base: app)
			} label: {
				Label(.localized("Install"), image: "icon-install")
			}
			Button {
				selectedSigningAppPresenting = AnyApp(base: app)
			} label: {
				Label(.localized("Sign"), image: "icon-sign")
			}
		}
	}
}
