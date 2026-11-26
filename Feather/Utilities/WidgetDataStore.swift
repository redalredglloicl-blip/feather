//
//  WidgetDataStore.swift
//  Zenith
//
//  Zenith v2.2 — shares the selected certificate with the home-screen
//  widget (ZenithWidget target) through the App Group
//  "group.com.zenith.app".
//
//  The app writes the certificate name + real ExpirationDate here
//  whenever the certificate changes or is loaded; the widget only
//  reads. If the App Group is not in the signing profile,
//  UserDefaults(suiteName:) is nil and sync() does nothing — the
//  widget then honestly shows "open the app" instead of a number.
//  No fake values are ever written here.

import Foundation
import WidgetKit

final class WidgetDataStore {
	static let shared = WidgetDataStore()

	/// App Group shared by the app and the ZenithWidget extension.
	/// Both targets must list it in their entitlements, and the
	/// signing profile must contain it, or sharing silently fails.
	static let appGroupID = "group.com.zenith.app"

	/// Keys — the widget reads these exact strings. Keep in sync
	/// with ZenithWidget.swift; there is no shared source file
	/// between the two targets.
	static let certNameKey = "Zenith.widget.certName"
	static let certExpirationKey = "Zenith.widget.certExpiration"
	static let updatedAtKey = "Zenith.widget.updatedAt"

	/// Widget kind, for targeted timeline reloads.
	static let widgetKind = "ZenithWidget"

	private init() {}

	/// Writes the selected certificate (name + real expiration date)
	/// to the shared defaults, or clears them when there is no
	/// certificate. Then asks WidgetKit to reload the widget.
	/// Safe to call from launch, foreground, and certificate changes.
	func sync() {
		guard let sharedDefaults = UserDefaults(suiteName: Self.appGroupID) else {
			return
		}

		let selectedIndex = UserDefaults.standard.integer(forKey: "zenith.selectedCert")
		let cert = Storage.shared.getCertificate(for: selectedIndex)
			?? Storage.shared.getAllCertificates().first

		guard let cert, let expiration = cert.expiration else {
			sharedDefaults.removeObject(forKey: Self.certNameKey)
			sharedDefaults.removeObject(forKey: Self.certExpirationKey)
			sharedDefaults.removeObject(forKey: Self.updatedAtKey)
			WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
			return
		}

		let name = cert.nickname
			?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name
			?? .localized("Unknown")
		sharedDefaults.set(name, forKey: Self.certNameKey)
		sharedDefaults.set(expiration, forKey: Self.certExpirationKey)
		sharedDefaults.set(Date(), forKey: Self.updatedAtKey)
		WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
	}
}
