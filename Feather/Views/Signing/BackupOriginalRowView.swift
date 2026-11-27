//
//  BackupOriginalRowView.swift
//  Zenith
//
//  Zenith v2.12, ITEM 5 — backup original before modding.
//  A row of the shared modding tools at the top of the signing
//  screen (with the IPA browser and the moddability check).
//
//  A toggle ("save the original copy before modding") plus the
//  status of the saved backup for this app. The toggle lives in
//  BackupManager.backupBeforeModding (ON by default, remembered
//  in UserDefaults) and gates BOTH backup hooks: the byte-identical
//  IPA copy in AppFileHandler.copy() and the re-zipped .app in
//  SigningHandler.copy(), which runs before modify() changes
//  anything (injection, custom name, file removal, ...).
//
//  WIRING (coordinator): drop this view into the "التعديل" section
//  as item 7 — after the hidden-dev-menus row, before the custom
//  name field (CustomDisplayNameField, item 8):
//
//    BackupOriginalRowView(app: app)
//
//  No state is owned here: the toggle and the status both read
//  BackupManager.shared, so the status line updates on its own
//  once a backup is saved. SigningView.swift is NOT edited by
//  this file.
//

import SwiftUI
import NimbleViews

// MARK: - Zenith v2.12, ITEM 5: backup-original row (item 7 of "التعديل")
/// The backup control for the signing screen's "التعديل" section
/// (item 7): a toggle to keep a copy of the original app before
/// modding, and the status of the backup saved for this app.
struct BackupOriginalRowView: View {
	var app: AppInfoPresentable
	
	@StateObject private var _backupManager = BackupManager.shared
	
	// MARK: Body
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Toggle(.localized("Save Original Copy Before Modding"), isOn: $_backupManager.backupBeforeModding)
			Text(.localized("Backup Original Hint"))
				.font(.footnote)
				.foregroundStyle(.secondary)
			Text(verbatim: _statusText)
				.font(.footnote)
				.foregroundStyle(_backupManager.latestBackup(appName: app.name, appVersion: app.version) == nil ? .secondary : Color(hex: "#FFC778"))
		}
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
	}
	
	/// Status line: the saved backup's name, date and size — or
	/// that no backup has been saved for this app yet.
	private var _statusText: String {
		guard let backup = _backupManager.latestBackup(appName: app.name, appVersion: app.version) else {
			return .localized("No Backup Saved Yet")
		}
		let dateText = backup.date.formatted(date: .abbreviated, time: .shortened)
		return .localized(
			"Backup Saved Detail",
			arguments: backup.appName, dateText, backup.sizeBytes.formattedByteCount
		)
	}
}
