//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//
//  Zenith has exactly three tabs — Home, Certificates and Settings —
//  by design. Certificates live in their own tab (moved out of
//  Settings in the Zenith v2 redesign). Tab icons are the hand-drawn
//  Zenith asset images, not SF Symbols.

import SwiftUI
import NimbleViews

enum TabEnum: String, CaseIterable, Hashable {
	case library
	case certificates
	case settings
	
	var title: String {
		switch self {
		case .library: 		return .localized("Home")
		case .certificates: 	return .localized("Certificates")
		case .settings: 	return .localized("Settings")
		}
	}
	
	/// Asset-catalog image name (hand-drawn Zenith icon), not an SF Symbol.
	var icon: String {
		switch self {
		case .library: 		return "icon-library"
		case .certificates: 	return "icon-certificates"
		case .settings: 	return "icon-settings"
		}
	}
	
	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
		case .library: LibraryView()
		case .certificates: NBNavigationView(.localized("Certificates")) {
			CertificatesView()
		}
		case .settings: SettingsView()
		}
	}
	
	static var defaultTabs: [TabEnum] {
		return [
			.library,
			.certificates,
			.settings
		]
	}
	
	static var customizableTabs: [TabEnum] {
		return []
	}
}
