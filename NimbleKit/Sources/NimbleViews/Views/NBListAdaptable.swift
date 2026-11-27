//
//  NBListAdaptable.swift
//  NimbleKit
//
//  Created by samara on 7.05.2025.
//

import SwiftUI

public struct NBListAdaptable<Content>: View where Content: View {
	private var _content: Content
	
	public init(@ViewBuilder content: () -> Content) {
		self._content = content()
	}
	
	public var body: some View {
		// Zenith v2.13: 2.0 REVERT — the Library is a plain list
		// on every size class, like the old 2.0 Library. The
		// regular-width path used to render a grid of large
		// glass cards (NBGrid); those cards are gone with the
		// capsule revert, and a grid of empty cards is exactly
		// the defect Reda reported. One compact list everywhere.
		List {
			_content
		}
		.listStyle(.plain)
	}
}
