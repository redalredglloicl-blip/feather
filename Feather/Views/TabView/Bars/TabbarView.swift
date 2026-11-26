//
//  TabbarView.swift
//  zenith
//
//  Created by samara on 23.03.2025.
//
//  Zenith v2.4: native tab bar (v2.2 layout). The tab icons are
//  96px PNGs, which render at intrinsic 96pt in a bare Label —
//  so each icon gets an explicit 24pt frame, the size the v2.3
//  floating bar used and the system tab-bar slot expects.
//  The bar itself is liquid glass on iOS 26+ via
//  .zenithTabBarBackground() (the system draws it); older iOS
//  gets a translucent material bar from the same modifier.

import SwiftUI

struct TabbarView: View {
	@State private var selectedTab: TabEnum = .library

	var body: some View {
		TabView(selection: $selectedTab) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						// Label form (not a bare Image+Text tuple):
						// the tab bar reads a Label's icon+title.
						Label {
							Text(tab.title)
						} icon: {
							Image(tab.icon)
								.resizable()
								.scaledToFit()
								.frame(width: 24, height: 24)
						}
					}
					.tag(tab)
			}
		}
		.zenithTabBarBackground()
	}
}
