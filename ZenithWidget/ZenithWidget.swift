//
//  ZenithWidget.swift
//  ZenithWidget
//
//  Zenith v2.2 — home-screen widget: days left on the certificate.
//
//  Data comes ONLY from the shared App Group "group.com.zenith.app",
//  written by WidgetDataStore in the main app (cert name + the real
//  ExpirationDate). The widget never invents a number: with no shared
//  data it says "افتح التطبيق لتحديث العدّاد" instead.
//
//  NOTE: the widget cannot read anything unless the App Group is in
//  BOTH targets' entitlements AND in the signing profile. With the
//  shared enterprise certificate that is not guaranteed — see
//  /tmp/zenith-widget-pbxproj-plan.md. The empty state below is the
//  honest fallback for exactly that case.

import Foundation
import SwiftUI
import WidgetKit

// MARK: - Shared keys (must match WidgetDataStore in the main app)

/// Peach accent. Defined here because the widget target does not
/// include the main app's Color(hex:) helper. #FFC778.
private extension Color {
	static let zenithPeach = Color(red: 1.0, green: 199 / 255, blue: 120 / 255)
}

private enum WidgetKeys {
	static let appGroupID = "group.com.zenith.app"
	static let certNameKey = "Zenith.widget.certName"
	static let certExpirationKey = "Zenith.widget.certExpiration"
}

// MARK: - Timeline

struct CertEntry: TimelineEntry {
	let date: Date
	/// Certificate display name, or nil when no shared data exists.
	let certName: String?
	/// Real expiration date from the certificate, or nil.
	let expiration: Date?

	/// Whole calendar days left, from today to the expiry day.
	/// Nil when there is no expiration date.
	var daysLeft: Int? {
		guard let expiration else { return nil }
		let calendar = Calendar.current
		return calendar.dateComponents(
			[.day],
			from: calendar.startOfDay(for: Date()),
			to: calendar.startOfDay(for: expiration)
		).day
	}
}

struct CertProvider: TimelineProvider {
	func placeholder(in context: Context) -> CertEntry {
		CertEntry(date: Date(), certName: nil, expiration: nil)
	}

	func getSnapshot(in context: Context, completion: @escaping (CertEntry) -> Void) {
		completion(_readEntry())
	}

	func getTimeline(in context: Context, completion: @escaping (Timeline<CertEntry>) -> Void) {
		let entry = _readEntry()
		// Reload after midnight so the days-left number stays right.
		let nextMidnight = Calendar.current.nextDate(
			after: Date(),
			matching: DateComponents(hour: 0, minute: 0),
			matchingPolicy: .nextTime
		) ?? Date().addingTimeInterval(86400)
		completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
	}

	/// Reads the shared defaults. A name without an expiry (or vice
	/// versa) is partial/stale data — treated as no data at all.
	private func _readEntry() -> CertEntry {
		let defaults = UserDefaults(suiteName: WidgetKeys.appGroupID)
		guard
			let name = defaults?.string(forKey: WidgetKeys.certNameKey),
			let expiration = defaults?.object(forKey: WidgetKeys.certExpirationKey) as? Date
		else {
			return CertEntry(date: Date(), certName: nil, expiration: nil)
		}
		return CertEntry(date: Date(), certName: name, expiration: expiration)
	}
}

// MARK: - View

struct ZenithWidgetEntryView: View {
	@Environment(\.widgetFamily) private var family

	var entry: CertEntry

	var body: some View {
		ZStack {
			Color.black
			if let name = entry.certName, let daysLeft = entry.daysLeft {
				_countdownView(name: name, daysLeft: daysLeft, expiration: entry.expiration)
			} else {
				_emptyView
			}
		}
	}

	@ViewBuilder
	private func _countdownView(name: String, daysLeft: Int, expiration: Date?) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(name)
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(1)

			if daysLeft < 0 {
				Text("الشهادة منتهية")
					.font(.headline)
					.foregroundStyle(.red)
			} else {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Text("\(daysLeft)")
						.font(.system(size: family == .systemMedium ? 44 : 36, weight: .bold))
						.foregroundStyle(Color.zenithPeach)
					Text(_daysLabel(daysLeft))
						.font(.headline)
						.foregroundStyle(.primary)
				}
			}

			if let expiration {
				Text(expiration, format: .dateTime.day().month().year())
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
		.padding()
	}

	/// Iraqi phrasing for the days count (1 يوم، 2 يومين، the rest N يوم).
	private func _daysLabel(_ days: Int) -> String {
		switch days {
		case 0:
			return "يخلص اليوم"
		case 1:
			return "يوم واحد باقي"
		case 2:
			return "يومين باقيات"
		default:
			return "يوم باقي"
		}
	}

	private var _emptyView: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Zenith")
				.font(.headline)
				.foregroundStyle(Color.zenithPeach)
			Text("افتح التطبيق لتحديث العدّاد")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(2)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
		.padding()
	}
}

// MARK: - Widget

struct ZenithWidget: Widget {
	let kind: String = "ZenithWidget"

	var body: some WidgetConfiguration {
		StaticConfiguration(kind: kind, provider: CertProvider()) { entry in
			ZenithWidgetEntryView(entry: entry)
		}
		.configurationDisplayName("Zenith")
		.description("عدّاد الأيام الباقية لشهادتك.")
		.supportedFamilies([.systemSmall, .systemMedium])
	}
}

@main
struct ZenithWidgetBundle: WidgetBundle {
	var body: some Widget {
		ZenithWidget()
	}
}
