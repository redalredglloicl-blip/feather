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
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		let isEditing = editMode?.wrappedValue == .active
		
		HStack(spacing: 18) {
			if isEditing {
				Button {
					_toggleSelection()
				} label: {
					Image(systemName: _isSelected ? "checkmark.circle.fill" : "circle")
						.foregroundColor(_isSelected ? .accentColor : .secondary)
						.font(.title2)
				}
				.buttonStyle(.borderless)
			}
			
			_appIcon(for: app)
			
			NBTitleWithSubtitleView(
				title: app.name ?? .localized("Unknown"),
				subtitle: _desc,
				linelimit: 0
			)
			
			if !isEditing {
				_buttonActions(for: app)
			}
		}
		.padding(isRegular ? 12 : 0)
		.zenithGlassCard(
			isEnabled: isRegular,
			cornerRadius: 18,
			fallback: _isSelected && isEditing ? Color.accentColor.opacity(0.1) : Color(.quaternarySystemFill)
		)
		.shadow(
			color: isRegular ? Color.black.opacity(0.18) : Color.clear,
			radius: isRegular ? 10 : 0,
			x: 0,
			y: isRegular ? 4 : 0
		)
		.contentShape(Rectangle())
		.onTapGesture {
			if isEditing {
				_toggleSelection()
			}
		}
		.swipeActions {
			if !isEditing {
				_actions(for: app)
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
	
	private var _desc: String {
		var lines: [String] = []
		
		if let version = app.version, let id = app.identifier {
			lines.append("\(version) • \(id)")
		} else {
			lines.append(.localized("Unknown"))
		}
		
		if app.isSigned, let expiration = Storage.shared.getCertificate(from: app)?.expiration {
			lines.append("\(Self._expiryDateFormatter.string(from: expiration)) (\(expiration.expirationInfo().formatted))")
		}
		
		if let uuid = app.uuid, let lastOpened = _prefs.lastOpenedDate(for: uuid) {
			lines.append("\(String.localized("Last opened")): \(Self._expiryDateFormatter.string(from: lastOpened))")
		} else {
			lines.append(.localized("Never opened"))
		}
		
		return lines.joined(separator: "\n")
	}
}


// MARK: - Extension: View
extension LibraryCellView {
	private func _appIcon(for app: AppInfoPresentable) -> some View {
		FRAppIconView(app: app, size: 57)
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
	
	@ViewBuilder
	private func _buttonActions(for app: AppInfoPresentable) -> some View {
		Group {
			Button {
				_prefs.toggleFavorite(uuid: app.uuid)
			} label: {
				Image("icon-favorite")
					.renderingMode(.template)
					.resizable()
					.scaledToFit()
					.frame(width: 22, height: 22)
					.foregroundStyle(_prefs.isFavorite(uuid: app.uuid) ? Color.accentColor : Color.secondary)
			}
			
			if app.isSigned {
				Button {
					selectedInstallAppPresenting = AnyApp(base: app)
				} label: {
					FRExpirationPillView(
						title: .localized("Install"),
						revoked: certRevoked,
						expiration: certInfo
					)
				}
			} else {
				Button {
					selectedSigningAppPresenting = AnyApp(base: app)
				} label: {
					FRExpirationPillView(
						title: .localized("Sign"),
						revoked: false,
						expiration: nil
					)
				}
			}
		}
		.buttonStyle(.borderless)
	}
}
