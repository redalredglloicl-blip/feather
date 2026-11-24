//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//
//  This build has exactly two tabs — Library and Settings — by design.
//  The Sources tab and its screens were removed entirely (see
//  FEATHER_MOD_PLAN.md). Certificates are reached from Settings.

import SwiftUI
import NimbleViews

enum TabEnum: String, CaseIterable, Hashable {
	case library
	case settings
	
	var title: String {
		switch self {
		case .library: 		return .localized("Library")
		case .settings: 	return .localized("Settings")
		}
	}
	
	var icon: String {
		switch self {
		case .library: 		return "square.grid.2x2"
		case .settings: 	return "gearshape.2"
		}
	}
	
	@ViewBuilder
	static func view(for tab: TabEnum) -> some View {
		switch tab {
		case .library: LibraryView()
		case .settings: SettingsView()
		}
	}
	
	static var defaultTabs: [TabEnum] {
		return [
			.library,
			.settings
		]
	}
	
	static var customizableTabs: [TabEnum] {
		return []
	}
}
