//
//  ZenithPolish.swift
//  Feather
//
//  Zenith v2 Phase 7 polish: liquid-glass surfaces, press-scale buttons,
//  blurred popup backgrounds and the animated signing-success screen.
//  Everything here is visual only — no logic, signing or networking code.
//  Glass uses `.glassEffect` (iOS 26 SDK) only behind `#available`,
//  with `.ultraThinMaterial` fallbacks so iOS 16 still builds and runs.
//

import SwiftUI

// MARK: - Liquid glass card
/// Applies a liquid-glass look to a card: real `.glassEffect` on iOS 26+,
/// a translucent material fill on older iOS. Replaces a plain rounded
/// background fill — do not stack it on top of an opaque fill.
struct ZenithGlassCardModifier: ViewModifier {
	var isEnabled: Bool = true
	var cornerRadius: CGFloat = 18
	var fallback: Color = Color(uiColor: .secondarySystemFill)

	@ViewBuilder
	func body(content: Content) -> some View {
		if isEnabled {
			if #available(iOS 26.0, *) {
				content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
			} else {
				content.background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
			}
		} else {
			content
		}
	}
}

extension View {
	/// Liquid-glass card background (iOS 26 glass, material fill below).
	func zenithGlassCard(
		isEnabled: Bool = true,
		cornerRadius: CGFloat = 18,
		fallback: Color = Color(uiColor: .secondarySystemFill)
	) -> some View {
		modifier(ZenithGlassCardModifier(isEnabled: isEnabled, cornerRadius: cornerRadius, fallback: fallback))
	}

	/// Tab bar background: the system already draws liquid glass on
	/// iOS 26; older iOS gets a translucent material bar instead.
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
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
