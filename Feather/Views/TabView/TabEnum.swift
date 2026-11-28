//
//  TabEnum.swift
//  zenith
//
//  Created by samara on 22.03.2025.
//
//  Zenith has exactly five tabs — Home, Certificates, Downloads,
//  Store and Settings, in that order — by design. Certificates
//  live in their own tab (moved out of Settings in the Zenith v2
//  redesign). The Store tab (2.34) sits next to Downloads, and
//  Settings is last (2.37). Tab icons are the hand-drawn
//  Zenith asset images, not SF Symbols.

import SwiftUI
import NimbleViews

enum TabEnum: String, CaseIterable, Hashable {
	case library
	case certificates
	case downloads
	case settings
	case store
	
	var title: String {
		switch self {
		case .library: 		return .localized("Home")
		case .certificates: 	return .localized("Certificates")
		case .downloads: 	return .localized("Downloads")
		case .settings: 	return .localized("Settings")
		case .store: 		return "المتجر"
		}
	}
	
	/// Asset-catalog image name (hand-drawn Zenith icon), not an SF Symbol.
	var icon: String {
		switch self {
		case .library: 		return "icon-library"
		case .certificates: 	return "icon-certificates"
		case .downloads: 	return "icon-download"
		case .settings: 	return "icon-settings"
		case .store: 		return "icon-store"
		}
	}
	
	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
		case .library: LibraryView()
		case .certificates: NBNavigationView(.localized("Certificates")) {
			CertificatesView()
		}
		case .downloads: DownloadsView()
		case .settings: SettingsView()
		case .store: ZenithStoreView()
		}
	}
	
	static var defaultTabs: [TabEnum] {
		return [
			.library,
			.certificates,
			.downloads,
			.store,
			.settings
		]
	}
	
	static var customizableTabs: [TabEnum] {
		return []
	}
}
