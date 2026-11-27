//
//  NavigationViewWrapper.swift
//  Stars
//
//  Created by samara on 7.04.2025.
//

import SwiftUI

public struct NBNavigationView<Content>: View where Content: View {
	private var _title: String
	private var _mode: NavigationBarItem.TitleDisplayMode
	private var _content: Content
	
	public init(
		_ title: String,
		displayMode: NavigationBarItem.TitleDisplayMode = .automatic,
		@ViewBuilder content: () -> Content
	) {
		self._title = title
		self._mode = displayMode
		self._content = content()
	}
	
	public var body: some View {
		NavigationStack {
			_content
				.navigationTitle(_title)
				.navigationBarTitleDisplayMode(_mode)
				// Zenith v2.13: the navigation bar is SOLID black,
				// like the old 2.0 layout. Without this the bar is
				// transparent on iOS 27 and the scrolling content
				// shows straight through it (Reda's 2.12 video:
				// the version subtitle half-visible under the
				// toolbar on the passport and signing screens).
				// Black matches the starfield base, so the bar
				// reads as the plain 2.0 bar, not a floating pill.
				.toolbarBackground(Color.black, for: .navigationBar)
				.toolbarBackground(.visible, for: .navigationBar)
		}
	}
}
