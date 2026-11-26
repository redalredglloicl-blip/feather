//
//  CertificateHeroCardView.swift
//  Feather
//
//  Zenith v2: the selected certificate as a beautiful card with an
//  animated countdown ring. Every number comes from the certificate
//  itself — the ring fraction is remaining days / total validity days
//  (ExpirationDate minus CreationDate from the provisioning profile),
//  and the days count is the real ExpirationDate. Nothing here is
//  faked: if the profile cannot be decoded, the ring is drawn empty
//  and only the stored expiration date is shown.
//

import SwiftUI
import NimbleViews

// MARK: - Hero card
struct CertificateHeroCardView: View {
	@ObservedObject var cert: CertificatePair
	
	@State private var _data: Certificate?
	@State private var _animatedFraction: Double = 0
	
	/// Days left until the real expiration date, never negative.
	private var _daysRemaining: Int {
		guard let expiration = cert.expiration else {
			return 0
		}
		return max(0, Int(expiration.timeIntervalSinceNow / 86400))
	}
	
	private var _isExpired: Bool {
		(cert.expiration ?? .distantFuture) <= Date()
	}
	
	/// Ring fraction: remaining validity / total validity of this
	/// certificate, from the provisioning profile. Nil when the profile
	/// cannot be decoded — the ring then shows no fill, honestly.
	private var _fraction: Double? {
		Self._fraction(from: _data)
	}
	
	private static func _fraction(from data: Certificate?) -> Double? {
		guard
			let data,
			data.ExpirationDate > data.CreationDate
		else {
			return nil
		}
		let total = data.ExpirationDate.timeIntervalSince(data.CreationDate)
		let remaining = data.ExpirationDate.timeIntervalSinceNow
		guard total > 0 else {
			return nil
		}
		return min(1, max(0, remaining / total))
	}
	
	/// Decodes the profile and animates the ring. The fraction is
	/// computed from the just-decoded value, not from state, so the
	/// first appearance animates correctly.
	private func _refreshData() {
		let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
		_data = decoded
		withAnimation(.easeOut(duration: 1.0)) {
			_animatedFraction = Self._fraction(from: decoded) ?? 0
		}
	}
	
	private var _ringColor: Color {
		// Mockup look: peach ring (the dream style). Red only when the
		// certificate is expired, so urgency is never hidden.
		_isExpired ? .red : Color(hex: "#FFC778")
	}
	
	private var _title: String {
		cert.nickname ?? _data?.Name ?? .localized("Unknown")
	}
	
	private var _subtitle: String {
		_data?.TeamName ?? _data?.AppIDName ?? ""
	}
	
	private var _expiryDateText: String {
		guard let expiration = cert.expiration else {
			return ""
		}
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .none
		return .localized("Expires on %@", arguments: formatter.string(from: expiration))
	}
	
	// MARK: Body
	var body: some View {
		VStack(spacing: 20) {
			CertificateCountdownRingView(
				fraction: _animatedFraction,
				hasFraction: _fraction != nil,
				daysLeft: _daysRemaining,
				isExpired: _isExpired,
				color: _ringColor
			)
			.frame(width: 220, height: 220)
			
			VStack(spacing: 4) {
				Text(_title)
					.font(.title2)
					.fontWeight(.bold)
					.lineLimit(2)
					.multilineTextAlignment(.center)
				
				if !_subtitle.isEmpty {
					Text(_subtitle)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				
				if let expiration = cert.expiration {
					let info = expiration.expirationInfo()
					HStack(spacing: 6) {
						Image(systemName: info.icon)
						Text(info.formatted)
					}
					.font(.footnote)
					.foregroundStyle(info.color)
				}
				
				if !_expiryDateText.isEmpty {
					Text(_expiryDateText)
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			}
		}
		.padding()
		.zenithGlassCard(cornerRadius: 18, fallback: Color(uiColor: .secondarySystemFill))
		.overlay(
			RoundedRectangle(cornerRadius: 18)
				.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
		.padding(.horizontal)
		.padding(.top, 8)
		.onAppear {
			_refreshData()
		}
		.onChange(of: cert.objectID) { _ in
			_refreshData()
		}
	}
}

// MARK: - Countdown ring
struct CertificateCountdownRingView: View {
	/// Animated fill fraction (0...1). Ignored when hasFraction is false.
	var fraction: Double
	/// False when the total validity is unknown — the ring shows no fill.
	var hasFraction: Bool
	var daysLeft: Int
	var isExpired: Bool
	var color: Color
	
	var body: some View {
		ZStack {
			Circle()
				.stroke(color.opacity(0.18), lineWidth: 14)
			
			if hasFraction {
				Circle()
					.trim(from: 0, to: fraction)
					.stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.shadow(color: color.opacity(0.75), radius: 16)
			}
			
			VStack(spacing: 4) {
				Text("\(daysLeft)")
					.font(.system(size: 64, weight: .bold, design: .rounded))
					.foregroundStyle(isExpired ? .secondary : Color.accentColor)
				Text(.localized("Days Remaining"))
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(.secondary)
			}
		}
	}
}
