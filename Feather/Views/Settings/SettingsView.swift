//
//  SettingsView.swift
//  Feather
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
						Label(.localized("Signing Options"), image: "icon-sign")
					}
					NavigationLink(destination: ArchiveView()) {
						Label(.localized("Archive & Compression"), image: "icon-archive")
					}
					NavigationLink(destination: InstallationView()) {
						Label(.localized("Installation"), image: "icon-install")
					}
					NavigationLink(destination: HelpCenterView()) {
						Label(.localized("مركز المساعدة"), image: "icon-info")
					}
				} footer: {
					Text(.localized("Configure the apps way of installing, its zip compression levels, and custom modifications to apps."))
				}
                
				_directories()
                
				Section {
					NavigationLink(destination: ResetView()) {
						Label(.localized("Reset"), image: "icon-delete")
					}
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
					HStack {
						Text(.localized("Version"))
						Spacer()
						Text(Bundle.main.version)
							.foregroundStyle(.secondary)
					}
				}
			}
			.scrollContentBackground(.hidden)
		}
		.starfieldBackground()
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
			Button(.localized("Open Archives"), systemImage: "folder") {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			}
			Button(.localized("Open Certificates"), systemImage: "folder") {
				UIApplication.open(FileManager.default.certificates.toSharedDocumentsURL()!)
			}
		} footer: {
			Text(.localized("All of the apps files are contained in the documents directory, here are some quick links to these."))
		}
	}
}
