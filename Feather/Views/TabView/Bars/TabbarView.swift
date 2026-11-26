//
//  TabbarView.swift
//  zenith
//
//  Created by samara on 23.03.2025.
//
//  Zenith v2.3: floating glass tab bar (mockup) — four separate
//  rounded-square glass buttons (Home / Certificates / Downloads /
//  Settings), peach-highlighted for the active tab. The native tab
//  bar is hidden, but the TabView itself, the selection binding and
//  every tab's view are untouched, so per-tab NavigationStack state
//  keeps working exactly as before. A bottom safe-area inset the
//  height of the floating bar keeps scrollable tab content from
//  sliding underneath it.
//
//  NOTE (wiring): VariedTabbarView routes every iOS version here
//  (v2.3), so this IS the live tab bar on Reda's iOS 27 phone —
//  the old iOS 18+ native-sidebar route (ExtendedTabbarView) is
//  unused dead code kept in the tree because snapshot pushes
//  cannot delete files.

import SwiftUI

struct TabbarView: View {
	@State private var selectedTab: TabEnum = .library

	var body: some View {
		GeometryReader { geo in
			ZStack(alignment: .bottom) {
				TabView(selection: $selectedTab) {
					ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
						TabEnum.view(for: tab)
							.tag(tab)
					}
				}
				// Native bar hidden; the floating glass bar below is
				// the only tab switcher. Hiding the bar changes no
				// navigation state — the TabView and its selection
				// binding are exactly as before.
				.toolbar(.hidden, for: .tabBar)
				// Reserve exactly the floating bar's footprint (gap
				// above the home indicator + bar + active-dot
				// protrusion) so tab content never hides under it.
				.safeAreaInset(edge: .bottom, spacing: 0) {
					Color.clear
						.frame(height: ZenithFloatingTabBar.reservedHeight)
				}

				ZenithFloatingTabBar(selectedTab: $selectedTab)
					.padding(.horizontal, 16)
					.padding(.bottom, geo.safeAreaInsets.bottom + ZenithFloatingTabBar.bottomGap)
			}
		}
	}
}

// MARK: - Floating glass tab bar
/// Four separate rounded-square glass buttons. The tab icons are the
/// hand-drawn Zenith assets (already peach — verified: every tab icon
/// is a single peach tone): the active tab shows them as-is with a
/// peach label, rim, tint and a dot above the button; inactive tabs
/// desaturate the icon to grey with a grey label. No SF Symbols and
/// no template rendering — the art is used exactly as drawn.
struct ZenithFloatingTabBar: View {
	@Binding var selectedTab: TabEnum

	/// Height of one glass button.
	static let buttonHeight: CGFloat = 64
	/// Gap between the bar's bottom edge and the bottom safe area.
	static let bottomGap: CGFloat = 10
	/// How far the active dot sticks up above a button.
	private static let _dotProtrusion: CGFloat = 12
	/// Total footprint to reserve with safeAreaInset (gap + bar +
	/// dot protrusion, on top of the system's own bottom safe area).
	static var reservedHeight: CGFloat {
		bottomGap + buttonHeight + _dotProtrusion
	}

	private static let _peach = Color(hex: "#FFC778")

	var body: some View {
		HStack(spacing: 10) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				_tabButton(for: tab, isActive: tab == selectedTab)
			}
		}
	}

	private func _tabButton(for tab: TabEnum, isActive: Bool) -> some View {
		Button {
			selectedTab = tab
		} label: {
			VStack(spacing: 3) {
				Image(tab.icon)
					.resizable()
					.scaledToFit()
					.frame(width: 24, height: 24)
					.saturation(isActive ? 1 : 0)
					.opacity(isActive ? 1 : 0.6)
				Text(verbatim: tab.title)
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(isActive ? Self._peach : Color.gray)
					.lineLimit(1)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.buttonStyle(ZenithPressButtonStyle())
		.frame(height: Self.buttonHeight)
		.background(
			RoundedRectangle(cornerRadius: 18, style: .continuous)
				.fill(Self._peach.opacity(isActive ? 0.16 : 0))
		)
		.zenithGlassCard(cornerRadius: 18)
		.overlay {
			RoundedRectangle(cornerRadius: 18, style: .continuous)
				.stroke(
					isActive ? Self._peach.opacity(0.6) : Color.white.opacity(0.14),
					lineWidth: isActive ? 1.5 : 1
				)
		}
		.shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
		.overlay(alignment: .top) {
			if isActive {
				Circle()
					.fill(Self._peach)
					.frame(width: 6, height: 6)
					.shadow(color: Self._peach.opacity(0.9), radius: 4, x: 0, y: 0)
					.offset(y: -9)
			}
		}
	}
}
