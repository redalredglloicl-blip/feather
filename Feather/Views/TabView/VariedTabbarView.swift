//
//  VariedTabbarView.swift
//  Zenith
//
//  Created by samara on 11.04.2025.
//

import SwiftUI

struct VariedTabbarView: View {
	init() {}
	
	var body: some View {
		// Zenith v2.3: the floating glass tab bar (mockup) is the tab
		// bar on every iOS version. The iOS 18+ native sidebar route
		// (ExtendedTabbarView) is no longer used — its tab
		// customization is dropped in favour of the mockup look.
		// ExtendedTabbarView.swift stays in the tree as dead code
		// (snapshot pushes cannot delete files); it still compiles.
		TabbarView()
	}
}
