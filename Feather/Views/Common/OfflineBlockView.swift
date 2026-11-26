//
//  OfflineBlockView.swift
//  Zenith
//
//  Zenith v2.3: no-internet block screen. Shown instead of the whole
//  app while the device has no internet. There is no dismiss and no
//  bypass — it disappears on its own the moment connectivity returns.

import SwiftUI

struct OfflineBlockView: View {
	var body: some View {
		VStack(spacing: 0) {
			Spacer()

			// Planet — drawn, same look as the approved app icon
			// (peach planet + ring on dark).
			ZStack {
				Circle()
					.fill(Color(hex: "#FFC778"))
					.frame(width: 72, height: 72)
				Ellipse()
					.stroke(Color(hex: "#FFC778"), lineWidth: 5)
					.frame(width: 128, height: 40)
					.rotationEffect(.degrees(-20))
			}
			.frame(width: 128, height: 128)
			.padding(.bottom, 24)

			Text(.localized("ماكو نت"))
				.font(.title2)
				.fontWeight(.bold)

			Text(.localized("شغّل الواي فاي أو بيانات الموبايل حتى يفتح التطبيق"))
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.top, 6)
				.padding(.horizontal, 32)

			Text(.localized("التطبيق يفتح وحده من يرجع النت"))
				.font(.footnote)
				.foregroundStyle(.secondary)
				.padding(.top, 16)

			Spacer()
		}
		.starfieldBackground()
	}
}
