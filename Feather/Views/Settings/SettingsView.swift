//
//  SettingsView.swift
//  Zenith
//
//  Created by samara on 10.04.2025.
//
//  Zenith: Certificates live in their own tab now, so the Certificates
//  section was removed from Settings. The Version row shows the bundle
//  version (2.0) so the user can tell the update arrived.

import SwiftUI
import NimbleViews
import NimbleExtensions
import UIKit
import Darwin
import IDeviceSwift

// MARK: - View
struct SettingsView: View {
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Settings")) {
			Form {
					NBSection(.localized("Features")) {
						NavigationLink(destination: ConfigurationView()) {
							_settingsRow(title: .localized("Signing Options"), icon: "icon-sign")
						}
						.zenithGlassCard(cornerRadius: 12)
						.listRowSeparator(.hidden)
						.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
						NavigationLink(destination: ArchiveView()) {
							_settingsRow(title: .localized("Archive & Compression"), icon: "icon-archive")
						}
						.zenithGlassCard(cornerRadius: 12)
						.listRowSeparator(.hidden)
						.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
						NavigationLink(destination: InstallationView()) {
							_settingsRow(title: .localized("Installation"), icon: "icon-install")
						}
						.zenithGlassCard(cornerRadius: 12)
						.listRowSeparator(.hidden)
						.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
						NavigationLink(destination: HelpCenterView()) {
							_settingsRow(title: .localized("مركز المساعدة"), icon: "icon-info")
						}
						.zenithGlassCard(cornerRadius: 12)
						.listRowSeparator(.hidden)
						.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
					} footer: {
						Text(.localized("Configure the apps way of installing, its zip compression levels, and custom modifications to apps."))
					}

					_directories()

					Section {
						NavigationLink(destination: ResetView()) {
							_settingsRow(title: .localized("Reset"), icon: "icon-delete")
						}
						.zenithGlassCard(cornerRadius: 12)
						.listRowSeparator(.hidden)
						.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
					} footer: {
						Text(.localized("Reset the application's certificates, apps, and files."))
					}

					Section {
						HStack {
							Text(.localized("Device Name"))
							Spacer()
							Text(UIDevice.current.name)
								.foregroundStyle(.secondary)
						}
						.zenithGlassCard(cornerRadius: 12)
						.listRowSeparator(.hidden)
						.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
						HStack {
							Text(.localized("Version"))
							Spacer()
							Text(Bundle.main.version)
								.foregroundStyle(.secondary)
						}
						.zenithGlassCard(cornerRadius: 12)
						.listRowSeparator(.hidden)
						.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
					}
				}
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.starfieldBackground()
				.listRowBackground(Color.clear)
			}
		}

	/// One settings row: a peach line icon at 20pt next to the title.
	/// v2.2 used a bare Label(image:) whose SVG scaled to the font
	/// size; the 96px PNGs need this explicit frame to render at
	/// that same size. Template-tinted peach, like the original art.
	private func _settingsRow(title: String, icon: String) -> some View {
		HStack(spacing: 12) {
			_rowIcon(icon)
			Text(title)
		}
	}

	/// A peach line icon PNG (transparent, 96px asset) rendered as a
	/// 20pt template image tinted with the peach accent color.
	private func _rowIcon(_ name: String) -> some View {
		Image(name)
			.renderingMode(.template)
			.resizable()
			.scaledToFit()
			.frame(width: 20, height: 20)
			.foregroundStyle(Color.accentColor)
	}
}

// MARK: - View extension
extension SettingsView {
	@ViewBuilder
	private func _directories() -> some View {
		NBSection(.localized("Misc")) {
			Button(.localized("Open Documents"), systemImage: "folder") {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			}
			.zenithGlassCard(cornerRadius: 12)
			.listRowSeparator(.hidden)
			.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
			Button(.localized("Open Archives"), systemImage: "folder") {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			}
			.zenithGlassCard(cornerRadius: 12)
			.listRowSeparator(.hidden)
			.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
			Button(.localized("Open Certificates"), systemImage: "folder") {
				UIApplication.open(FileManager.default.certificates.toSharedDocumentsURL()!)
			}
			.zenithGlassCard(cornerRadius: 12)
			.listRowSeparator(.hidden)
			.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
		} footer: {
			Text(.localized("All of the apps files are contained in the documents directory, here are some quick links to these."))
		}
	}
}
