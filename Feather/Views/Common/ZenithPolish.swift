//
//  ZenithPolish.swift
//  Zenith
//
//  Zenith v2 Phase 7 polish: press-scale buttons, blurred popup
//  backgrounds and the animated signing-success screen.
//  Everything here is visual only — no logic, signing or networking code.
//
//  Zenith v2.13: 2.0 REVERT — the whole app is back to the old
//  Feather 2.0 layout: plain flat rows in one rounded section card,
//  hairline separators between rows, NO inner capsules anywhere.
//  The capsule defect (Reda's 2026-11-27 video): every row label
//  carried `.zenithGlassCard`, which drew a LIGHTER rounded rect
//  (`secondarySystemFill`) + shadow behind the label, floating
//  inside the darker section card — a white horizontal capsule
//  across the middle of every row. The modifier below no longer
//  draws that: it is a plain flat fill in the SECTION colour
//  (`secondarySystemGroupedBackground`, the same fill the system
//  grouped list uses for its section cards), with NO shadow and
//  NO stroke/outline. It is kept, with the same API, ONLY for
//  standalone section blocks (certificate hero, DNS card, expiry
//  banner, update banner, success popup) — one flat fill per
//  block, never nested inside another card. Rows inside a Form
//  or List must NOT use it: rows are plain, separators visible,
//  the system section fill behind them. NEVER re-add a lighter
//  fill, a shadow, a glass effect or a stroke to this modifier:
//  separation is the section fill + hairline separators only.
//  The only strokes left in the app are functional drawings
//  (countdown/progress rings, the success checkmark, the planet
//  logo, selection rings, tint-swatch rings, app-icon hairlines).
//

import SwiftUI

// MARK: - Flat section fill (v2.13: 2.0 revert — was Liquid Glass,
// then a lighter capsule; see the header above)
/// A plain flat section fill: a rounded rectangle in the section
/// tone, no shadow, no glass, no rim. Deliberately NOT a lighter
/// capsule — the lighter fill + shadow read as a white capsule
/// inside every section on Reda's phone (v2.12 video). Use only
/// for standalone section blocks, never on rows inside a Form
/// or List.
struct ZenithGlassCardModifier: ViewModifier {
	var isEnabled: Bool = true
	var cornerRadius: CGFloat = 18
	var fallback: Color = Color(uiColor: .secondarySystemGroupedBackground)

	@ViewBuilder
	func body(content: Content) -> some View {
		if isEnabled {
			content
				.background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
		} else {
			content
		}
	}
}

extension View {
	/// Flat section fill (plain, v2.13 — no glass, no rim, no
	/// shadow). No outline lines. Standalone section blocks only —
	/// never on rows inside a Form or List.
	func zenithGlassCard(
		isEnabled: Bool = true,
		cornerRadius: CGFloat = 18,
		fallback: Color = Color(uiColor: .secondarySystemGroupedBackground)
	) -> some View {
		modifier(ZenithGlassCardModifier(isEnabled: isEnabled, cornerRadius: cornerRadius, fallback: fallback))
	}

	/// Tab bar background: the system already draws liquid glass on
	/// iOS 26; older iOS gets a translucent material bar instead.
	/// Zenith v2.11: the system tab bar's own glass rim is Apple's,
	/// not app-drawn — it is left alone (see item 3 report).
	@ViewBuilder
	func zenithTabBarBackground() -> some View {
		if #available(iOS 26.0, *) {
			self
		} else {
			self
				.toolbarBackground(.ultraThinMaterial, for: .tabBar)
				.toolbarBackground(.visible, for: .tabBar)
		}
	}

	/// Blurred popup background: on iOS 26 sheets are liquid glass by
	/// default, so nothing is overridden; older iOS gets a translucent
	/// material sheet background. System alerts already blur, so they
	/// are left alone.
	@ViewBuilder
	func zenithSheetBackground() -> some View {
		if #available(iOS 26.0, *) {
			self
		} else if #available(iOS 16.4, *) {
			self.presentationBackground(.ultraThinMaterial)
		} else {
			self
		}
	}
}

// MARK: - Press scale
/// Primary-action buttons scale down slightly while pressed, like iOS.
/// Appearance is untouched — only the press scale is added.
struct ZenithPressButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? 0.96 : 1.0)
			.animation(.easeOut(duration: 0.15), value: configuration.isPressed)
	}
}

// MARK: - Signing success screen
/// Full-screen success view shown after a signing finishes: a checkmark
/// that draws itself in, the app name, and a dismiss button. Presented
/// as an overlay (not a second sheet) so it never stacks on top of the
/// signing sheet.
struct SigningSuccessView: View {
	var appName: String
	var onDone: () -> Void

	@State private var _checkmarkProgress: CGFloat = 0
	@State private var _circleScale: CGFloat = 0.5
	@State private var _contentOpacity: Double = 0

	var body: some View {
		ZStack {
			// Starfield is the bottom layer of this overlay, not a
			// .background() behind a dimming overlay: the old
			// black-45% veil sat on top of the stars and buried them.
			// The starfield's own black base already hides the
			// signing sheet behind this overlay, so no veil is needed.
			StarfieldBackground()

			VStack(spacing: 18) {
				ZStack {
					Circle()
						.stroke(Color.accentColor.opacity(0.25), lineWidth: 6)
						.frame(width: 92, height: 92)

					Path { path in
						path.move(to: CGPoint(x: 30, y: 47))
						path.addLine(to: CGPoint(x: 41, y: 58))
						path.addLine(to: CGPoint(x: 64, y: 34))
					}
					.trim(from: 0, to: _checkmarkProgress)
					.stroke(
						Color.accentColor,
						style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
					)
					.frame(width: 92, height: 92)
				}
				.scaleEffect(_circleScale)

				VStack(spacing: 4) {
					Text(appName)
						.font(.headline)
						.lineLimit(2)
						.multilineTextAlignment(.center)
					Text(.localized("Signed"))
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}

				Button {
					onDone()
				} label: {
					Text(.localized("Dismiss"))
						.fontWeight(.semibold)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 12)
						.background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
						.foregroundStyle(.black)
				}
				.buttonStyle(ZenithPressButtonStyle())
			}
			.padding(28)
			.zenithGlassCard(cornerRadius: 24)
			.padding(.horizontal, 32)
			.opacity(_contentOpacity)
		}
		// Full-screen so the starfield fills the overlay, however the
		// signing sheet presents this view.
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onAppear {
			withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
				_circleScale = 1
				_contentOpacity = 1
			}
			withAnimation(.easeOut(duration: 0.45).delay(0.2)) {
				_checkmarkProgress = 1
			}
		}
	}
}
