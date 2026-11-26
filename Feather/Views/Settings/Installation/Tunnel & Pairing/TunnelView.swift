//
//  SettingsTunnelView.swift
//  Zenith (idevice)
//
//  Created by samara on 29.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift

// MARK: - View
struct TunnelView: View {
	@State private var _isImportingPairingPresenting = false
	
	@State var doesHavePairingFile = false
	@State private var isLocalDevVpnAvailable = false
	
	// MARK: Body
	var body: some View {
		Group {
			Section {
				if #available(iOS 17.4, *) {
				} else {
					_tunnelInfo()
						.zenithGlassCard(cornerRadius: 12)
						.listRowSeparator(.hidden)
						.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
					TunnelHeaderView()
						.zenithGlassCard(cornerRadius: 12)
						.listRowSeparator(.hidden)
						.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
				}
			} footer: {
				if doesHavePairingFile {
					Text(.localized("Seems like you've gotten your hands on your pairing file!"))
				} else {
					Text(.localized("No pairing file found, please import it."))
				}
			}
			
			Section {
				Button {
					_isImportingPairingPresenting = true
				} label: {
					Label {
						Text(.localized("Import Pairing File"))
					} icon: {
						Image("icon-import")
							.resizable()
							.scaledToFit()
							.frame(width: 20, height: 20)
					}
				}
				.zenithGlassCard(cornerRadius: 12)
				.listRowSeparator(.hidden)
				.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
				if #available(iOS 17.4, *) {
				} else {
					Button(.localized("Restart Heartbeat"), systemImage: "arrow.counterclockwise") {
						HeartbeatManager.shared.start(true)	
						DispatchQueue.global(qos: .userInitiated).async {
							if !HeartbeatManager.shared.checkSocketConnection().isConnected {
								DispatchQueue.main.async {
									UIAlertController.showAlertWithOk(
										title: "Socket",
										message: "Unable to connect to TCP. Make sure you have loopback VPN enabled and you are on WiFi or Airplane mode."
									)
								}
							}
						}
					}
					.zenithGlassCard(cornerRadius: 12)
					.listRowSeparator(.hidden)
					.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
				}
			}
			
			NBSection(.localized("Help")) {
				if isLocalDevVpnAvailable {
					Button(.localized("Connect to LocalDevVPN"), systemImage: "link") {
						UIApplication.open("localdevvpn://enable?scheme=zenith")
					}
					.zenithGlassCard(cornerRadius: 12)
					.listRowSeparator(.hidden)
					.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
				} else {
					Button(.localized("Download LocalDevVPN"), systemImage: "arrow.down.app") {
						UIApplication.open("https://apps.apple.com/us/app/localdevvpn/id6755608044")
					}
					.zenithGlassCard(cornerRadius: 12)
					.listRowSeparator(.hidden)
					.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
				}
			}
		}
		.sheet(isPresented: $_isImportingPairingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes:  [.xmlPropertyList, .plist, .mobiledevicepairing],
				onDocumentsPicked: { urls in
					guard let selectedFileURL = urls.first else { return }
					Zenith.movePairing(selectedFileURL)
					doesHavePairingFile = true
				}
			)
			.ignoresSafeArea()
		}
		.onAppear {
			doesHavePairingFile = FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())
				? true
				: false
			if let url = URL(string: "localdevvpn://") {
				isLocalDevVpnAvailable = UIApplication.shared.canOpenURL(url)
			} else {
				isLocalDevVpnAvailable = false
			}
		}
	}
	
	@ViewBuilder
	private func _tunnelInfo() -> some View {
		HStack {
			VStack(alignment: .leading, spacing: 6) {
				Text(.localized("Heartbeat"))
					.font(.headline)
				Text(.localized("The heartbeat is activated in the background, it will restart when the app is re-opened or prompted. If the status below is pulsing, that means its healthy."))
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
		}
	}
}
