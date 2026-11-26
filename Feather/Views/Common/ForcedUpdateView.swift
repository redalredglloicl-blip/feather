
//
//  ForcedUpdateView.swift
//  Zenith
//
//  Zenith forced update screen (v2, Phase 5). Shown instead of the
//  whole app while the server says this build must update. There is
//  no dismiss and no bypass — the only way out is the update button
//  (when an update link is known).

import SwiftUI

struct ForcedUpdateView: View {
	@ObservedObject private var _manager = ForcedUpdateManager.shared
	
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
			
			Text(.localized("تحديث جديد نزل"))
				.font(.title2)
				.fontWeight(.bold)
			
			// The new version's name (e.g. "2.3") when the server
			// knows it — plain "Zenith" when the field is absent.
			Text(_manager.latestVersionName.map { "Zenith \($0)" } ?? "Zenith")
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.padding(.top, 6)
			
			Button {
				if let url = _manager.updateURL {
					UIApplication.shared.open(url)
				}
			} label: {
				Text(.localized("حدّث هسه"))
					.font(.headline)
					.frame(maxWidth: .infinity)
					.padding()
					.background(Color(hex: "#FFC778"))
					.foregroundStyle(.black)
					.clipShape(RoundedRectangle(cornerRadius: 14))
			}
			.disabled(_manager.updateURL == nil)
			.padding(.horizontal, 32)
			.padding(.top, 32)
			
			Spacer()
		}
		.starfieldBackground()
	}
}
