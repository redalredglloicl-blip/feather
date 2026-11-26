//
//  ArchiveView.swift
//  Zenith
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import Zip
import NimbleViews

// MARK: - View
struct ArchiveView: View {
	@AppStorage("Zenith.compressionLevel") private var _compressionLevel: Int = ZipCompression.DefaultCompression.rawValue
	@AppStorage("Zenith.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Archive & Compression")) {
			Section {
				Picker(selection: $_compressionLevel) {
					ForEach(ZipCompression.allCases, id: \.rawValue) { level in
						Text(level.label).tag(level)
					}
				} label: {
					Label {
						Text(.localized("Compression Level"))
					} icon: {
						Image("icon-archive")
							.resizable()
							.scaledToFit()
							.frame(width: 20, height: 20)
					}
				}
				.zenithGlassCard(cornerRadius: 12)
				.listRowSeparator(.hidden)
			}
			
			Section {
				Toggle(isOn: $_useShareSheet) {
					Label {
						Text(.localized("Show Sheet when Exporting"))
					} icon: {
						Image("icon-export")
							.resizable()
							.scaledToFit()
							.frame(width: 20, height: 20)
					}
				}
				.zenithGlassCard(cornerRadius: 12)
				.listRowSeparator(.hidden)
			} footer: {
				Text(.localized("Toggling show sheet will present a share sheet after exporting to your files."))
			}
		}
		.starfieldBackground()
	}
}
