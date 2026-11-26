//
//  HelpCenterView.swift
//  Zenith
//
//  Zenith v2.2: Help Center — plain-language Iraqi-Arabic fixes for
//  the errors users actually hit, plus a diagnostics section showing
//  the last error the app recorded (ZenithLastError, written from the
//  sign/install error paths). No fake advice: every fix names the
//  real place in iOS Settings where the thing is done.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct HelpCenterView: View {
	@State private var _lastError: (message: String, date: Date?)? = ZenithLastError.last

	private static let _errorDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .short
		return formatter
	}()

	// MARK: Body
	var body: some View {
		ZStack {
			StarfieldBackground()
			NBNavigationView(.localized("مركز المساعدة"), displayMode: .inline) {
				List {
					NBSection(.localized("أخطاء شائعة")) {
						_fix(
							title: .localized("المطور غير موثوق"),
							steps: [
								.localized("افتح إعدادات الآيفون وابحث عن «VPN وإدارة الجهاز»."),
								.localized("اضغط على اسم الشهادة أو الفريق."),
								.localized("اضغط «الوثوق» وبعدين أكّد."),
								.localized("ارجع وافتح التطبيق — لازم يشتغل هسه."),
							]
						)
						_fix(
							title: .localized("فشل التثبيت"),
							steps: [
								.localized("تأكد عندك مساحة فاضية بالآيفون."),
								.localized("إذا التطبيق مثبّت قبل، احذف النسخة القديمة وثبّت من جديد."),
								.localized("تأكد الشهادة ما منتهية — شوف تبويب الشهادات."),
								.localized("إذا تكرر، وقّع التطبيق من جديد وبعدين ثبّته."),
							]
						)
						_fix(
							title: .localized("الشهادة مسحوبة"),
							steps: [
								.localized("روح لتبويب الشهادات واضغط «تحديث» على صحة الشهادة حتى تتأكد."),
								.localized("إذا طلعت مسحوبة، جيب شهادة جديدة من تبويب الشهادات."),
								.localized("وقّع كل تطبيقاتك بالشهادة الجديدة وثبّتها من جديد."),
								.localized("ثبّت الحماية ضد السحب من تبويب الشهادات حتى ما تتكرر المشكلة."),
							]
						)
						_fix(
							title: .localized("فشل التوقيع"),
							steps: [
								.localized("تأكد مختار شهادة من شاشة التوقيع وإنها ما منتهية."),
								.localized("إذا الشهادة من أبل، جرّب تجديدها من تبويب الشهادات."),
								.localized("شوف آخر خطأ مسجّل تحت — هو يقول شنو صار بالضبط."),
								.localized("إذا الخطأ يذكر كلمة المرور، أعد إضافة الشهادة بكلمة المرور الصحيحة."),
							]
						)
					}

					NBSection(.localized("التشخيص")) {
						if let error = _lastError {
							VStack(alignment: .leading, spacing: 6) {
								Text(.localized("آخر خطأ مسجّل"))
									.font(.headline)
								Text(error.message)
									.font(.subheadline)
								if let date = error.date {
									Text(Self._errorDateFormatter.string(from: date))
										.font(.footnote)
										.foregroundStyle(.secondary)
								}
							}
							.zenithGlassCard(cornerRadius: 12)
							.listRowSeparator(.hidden)
							.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
							Button(.localized("مسح السجل"), role: .destructive) {
								ZenithLastError.clear()
								_lastError = nil
							}
							.zenithGlassCard(cornerRadius: 12)
							.listRowSeparator(.hidden)
							.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
						} else {
							Text(.localized("ما صار أي خطأ مسجّل — إذا صار خطأ بالتوقيع أو التثبيت، راح يطلع هنا."))
								.font(.footnote)
								.foregroundStyle(.secondary)
								.background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
								.zenithGlassCard(cornerRadius: 12)
								.listRowSeparator(.hidden)
								.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
						}
					}
				}
				// Transparent list so the starfield shows through the gaps
				// between rows; rows themselves stay clear as well.
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.listRowBackground(Color.clear)
			}
		}
	}

	// MARK: Fix card

	@ViewBuilder
	private func _fix(title: String, steps: [String]) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title)
				.font(.headline)
			ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
				HStack(alignment: .top, spacing: 8) {
					Text("\(index + 1).")
						.font(.subheadline)
						.fontWeight(.bold)
						.foregroundStyle(Color.accentColor)
					Text(step)
						.font(.subheadline)
				}
			}
		}
		.padding(.vertical, 4)
		.zenithGlassCard(cornerRadius: 12)
		.listRowSeparator(.hidden)
		.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
	}
}
