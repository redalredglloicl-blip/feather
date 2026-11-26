//
//  CertificateHealthView.swift
//  Feather
//
//  Zenith v2.2: health card shown under the certificate hero card in
//  the Certificates tab. Shows the honest result of the OCSP check
//  (healthy / revoked / could-not-verify) with a refresh button.
//  A "could not verify" result is never dressed up as healthy.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct CertificateHealthView: View {
	var cert: CertificatePair

	@StateObject private var _checker = CertificateHealthChecker()

	private static let _checkedFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .none
		formatter.timeStyle = .short
		return formatter
	}()

	// MARK: Body
	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 10) {
				Image("icon-protection")
					.renderingMode(.template)
					.resizable()
					.scaledToFit()
					.frame(width: 24, height: 24)
					.foregroundStyle(Color.accentColor)

				Text(.localized("صحة الشهادة"))
					.font(.headline)

				Spacer()

				Button {
					_checker.check(cert: cert)
				} label: {
					Label(.localized("تحديث"), image: "icon-renew")
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.disabled(_checker.status == .checking)
			}

			HStack(spacing: 8) {
				_statusDot
				Text(_statusText)
					.font(.subheadline)
					.foregroundStyle(_statusColor)
			}

			if case .unverified(let reason) = _checker.status, let reason, !reason.isEmpty {
				Text(reason)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if _checker.status == .revoked {
				Text(.localized("الشهادة مسحوبة — التطبيقات الموقعة بيها ما راح تنفتح. جيب شهادة جديدة ووقّع التطبيقات من جديد."))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if let lastChecked = _checker.lastChecked {
				Text(.localized("آخر فحص: %@", arguments: Self._checkedFormatter.string(from: lastChecked)))
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
		}
		.padding()
		.zenithGlassCard(cornerRadius: 18, fallback: Color(uiColor: .secondarySystemFill))
		.padding(.horizontal)
		.padding(.top, 8)
		.onAppear {
			if _checker.status == .unknown {
				_checker.check(cert: cert)
			}
		}
		.onChange(of: cert.objectID) { _ in
			_checker.check(cert: cert)
		}
	}

	// MARK: Status presentation

	private var _statusDot: some View {
		let color = _statusColor
		return Circle()
			.fill(color)
			.frame(width: 10, height: 10)
	}

	private var _statusColor: Color {
		switch _checker.status {
		case .unknown: .secondary
		case .checking: .secondary
		case .healthy: .green
		case .revoked: .red
		case .unverified: .orange
		}
	}

	private var _statusText: String {
		switch _checker.status {
		case .unknown:
			.localized("ما انفحصت بعد")
		case .checking:
			.localized("جارٍ الفحص...")
		case .healthy:
			.localized("سليمة — أبل ما ساحبتها")
		case .revoked:
			.localized("مسحوبة من أبل")
		case .unverified:
			.localized("ما گدرنا نتأكد — تحقق من النت وحاول مرة ثانية")
		}
	}
}
