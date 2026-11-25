//
//  TabbarController.swift
//  feather
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//
//  Three tabs: Home, Certificates and Settings. The Sources section
//  was removed entirely (see FEATHER_MOD_PLAN.md).

import SwiftUI

@available(iOS 18, *)
struct ExtendedTabbarView: View {
	@AppStorage("Feather.tabCustomization") var customization = TabViewCustomization()
	
	var body: some View {
		TabView {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				Tab(tab.title, image: tab.icon) {
					TabEnum.view(for: tab)
				}
			}
		}
		.tabViewStyle(.sidebarAdaptable)
		.tabViewCustomization($customization)
		.zenithTabBarBackground()
	}
}
