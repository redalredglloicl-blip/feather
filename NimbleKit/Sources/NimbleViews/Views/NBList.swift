//
//  NBList.swift
//  NimbleKit
//
//  Created by samara on 7.05.2025.
//

import SwiftUI

public struct NBList<Content>: View where Content: View {
	public enum NBListType {
		case list
		case form
	}
	
	private var _title: String
	private var _mode: NavigationBarItem.TitleDisplayMode
	private var _type: NBListType
	private var _content: Content
	
	public init(
		_ title: String,
		displayMode: NavigationBarItem.TitleDisplayMode = .automatic,
		type: NBListType = .form,
		@ViewBuilder content: () -> Content
	) {
		self._title = title
		self._mode = displayMode
		self._type = type
		self._content = content()
	}
	
	public var body: some View {
		Group {
			switch _type {
			case .form:
				Form {
					_content
				}
				// Zenith v2.8: every NBList caller is a pushed
				// sub-screen — the scroll background and the rows
				// stay clear so the starfield each caller layers
				// behind (`.starfieldBackground()`) shows through,
				// exactly like the tab roots do it.
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.listRowBackground(Color.clear)
			case .list:
				List {
					_content
				}
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.listRowBackground(Color.clear)
			}
		}
		.navigationTitle(_title)
		.navigationBarTitleDisplayMode(_mode)
	}
}
