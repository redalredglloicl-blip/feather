//
//  CertificateHealthView.swift
//  Zenith
//
//  Zenith v2.3: health card shown under the certificate hero card in
//  the Certificates tab. The verdict comes from the LOCAL file check
//  (p12 + provisioning profile expiry, parsed on device) — the online
//  OCSP check is best-effort only and can never make the headline a
//  network error. There is no "check the internet and try again"
//  state anywhere in this view: when nothing can be verified, the
//  card says so with the real reason.
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

	private static let _dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .none
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

			// The real reason when nothing could be verified — wrong
			// password, damaged file, missing files, ... Never a
			// network error as the headline.
			if let reason = _reasonText, !reason.isEmpty {
				Text(reason)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			// The local verdict stands; only this note says the
			// online check could not run.
			if _isOnlineUnavailable {
				Text(.localized("الفحص الأونلاين مو متوفر هسه — هاي النتيجة من فحص ملفات الشهادة نفسها."))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if let details = _details {
				_detailsRows(details)
			}

			if case .expired = _checker.status {
				Text(.localized("الشهادة منتهية — جدّدها ووقّع التطبيقات من جديد."))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if case .revoked = _checker.status {
				Text(.localized("الشهادة مسحوبة — التطبيقات الموقعة بيها ما راح تنفتح. جيب شهادة جديدة ووقّع التطبيقات من جديد."))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if let lastChecked = _checker.lastChecked {
				Text(verbatim: .localized("آخر فحص: %@", arguments: Self._checkedFormatter.string(from: lastChecked)))
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
		case .expiringSoon: .orange
		case .expired: .red
		case .revoked: .red
		case .invalid: .orange
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
		case .expiringSoon(let details, _):
			if let daysLeft = details.daysLeft {
				return .localized("راح تنتهي قريباً — باقي %lld يوم", arguments: daysLeft)
			}
			return .localized("راح تنتهي قريباً")
		case .expired:
			.localized("الشهادة منتهية")
		case .revoked:
			.localized("مسحوبة من أبل")
		case .invalid, .unverified:
			.localized("ما گدرنا نتأكد من الشهادة")
		}
	}

	/// Local details to show under the verdict, when the local parse
	/// produced any.
	private var _details: LocalCertificateDetails? {
		switch _checker.status {
		case .healthy(let details, _):
			details
		case .expiringSoon(let details, _):
			details
		case .expired(let details):
			details
		case .revoked(let details):
			details
		default:
			nil
		}
	}

	/// True when the local verdict is shown but the online check
	/// could not run.
	private var _isOnlineUnavailable: Bool {
		switch _checker.status {
		case .healthy(_, let onlineUnavailable):
			onlineUnavailable
		case .expiringSoon(_, let onlineUnavailable):
			onlineUnavailable
		default:
			false
		}
	}

	/// The real reason when the certificate could not be verified.
	private var _reasonText: String? {
		switch _checker.status {
		case .invalid(let reason):
			reason
		case .unverified(let reason):
			reason
		default:
			nil
		}
	}

	// MARK: Details rows

	@ViewBuilder
	private func _detailsRows(_ details: LocalCertificateDetails) -> some View {
		if let expiry = details.effectiveExpiry {
			Text(verbatim: .localized("Expires on %@", arguments: Self._dateFormatter.string(from: expiry)))
				.font(.footnote)
				.foregroundStyle(.secondary)
		}

		if let teamName = details.provisionTeamName, !teamName.isEmpty {
			HStack(spacing: 4) {
				Text(.localized("Team Name"))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Text(teamName)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}

		if let appIDName = details.provisionAppIDName, !appIDName.isEmpty {
			HStack(spacing: 4) {
				Text(.localized("App ID"))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Text(appIDName)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}

		if let issuer = details.p12Issuer, !issuer.isEmpty {
			HStack(spacing: 4) {
				Text(.localized("المُصدِر"))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Text(issuer)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}

		if let p12Problem = details.p12Problem, !p12Problem.isEmpty {
			Text(p12Problem)
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}
}
