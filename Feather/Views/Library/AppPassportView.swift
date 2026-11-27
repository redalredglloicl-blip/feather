//
//  AppPassportView.swift
//  Zenith
//
//  Zenith v2.2: the app "passport" — a detail screen for one Library
//  app. Every number shown comes from real data: the version and
//  MinimumOSVersion from the bundle's own Info.plist, the file size
//  measured from the app's real directory on disk, the install date
//  from the Library record, the last-opened date from LibraryPrefs,
//  and the certificate name / days left from the real certificate
//  that signed it. The big button re-signs through the existing
//  SigningView flow.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct AppPassportView: View {
	var app: AppInfoPresentable

	@ObservedObject private var _prefs = LibraryPrefs.shared
	@State private var _fileSizeText: String?
	@State private var _signingPresented = false

	private static let _dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .none
		return formatter
	}()

	private var _certificate: CertificatePair? {
		Storage.shared.getCertificate(from: app)
	}

	// MARK: Body
	var body: some View {
		ZStack {
			StarfieldBackground()
			NBNavigationView(app.name ?? .localized("Unknown"), displayMode: .inline) {
				List {
					Section {} header: {
						VStack(spacing: 10) {
							ZenithAppIconView(app: app, size: 87)
							Text(app.name ?? .localized("Unknown"))
								.font(.headline)
							if let version = app.version {
								Text(verbatim: .localized("الإصدار %@", arguments: version))
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
						}
						.frame(maxWidth: .infinity, alignment: .center)
						.padding(.bottom, 8)
					}

					_infoSection
					_certSection

					Section {
						Button {
							_signingPresented = true
						} label: {
							HStack {
								Spacer()
								// icon-sign is a 96px PNG: a bare Label(image:)
								// renders it at intrinsic 96pt. Explicit 20pt
								// frame = the size the v2.2 SVG scaled to.
								Label {
									Text(app.isSigned ? .localized("أعد توقيع التطبيق") : .localized("وقّع التطبيق"))
								} icon: {
									Image("icon-sign")
										.resizable()
										.scaledToFit()
										.frame(width: 20, height: 20)
								}
								.font(.headline)
								Spacer()
							}
						}
						.buttonStyle(ZenithPressButtonStyle())
					}
					.listRowBackground(Color.accentColor.opacity(0.15))
				}
				// Transparent list so the starfield shows through the gaps
				// between rows; rows themselves stay clear as well. The
				// sign button row keeps its translucent peach tint.
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.listRowBackground(Color.clear)
				.toolbar {
					NBToolbarButton(role: .close)
				}
				.task {
					_fileSizeText = await _measuredFileSizeText()
				}
				.fullScreenCover(isPresented: $_signingPresented) {
					SigningView(app: app)
				}
			}
		}
	}

	// MARK: Sections

	@ViewBuilder
	private var _infoSection: some View {
		NBSection(.localized("معلومات التطبيق")) {
			if let version = app.version {
				_infoCell(.localized("الإصدار"), desc: version)
			}
			if let identifier = app.identifier {
				_infoCell(.localized("المعرّف"), desc: identifier)
			}
			_infoCell(.localized("حجم الملف"), desc: _fileSizeText ?? .localized("جارٍ الحساب..."))
			if let date = app.date {
				_infoCell(.localized("تاريخ التثبيت"), desc: Self._dateFormatter.string(from: date))
			}
			if let lastOpened = _prefs.lastOpenedDate(for: app.uuid) {
				_infoCell(.localized("آخر مرة انفتح"), desc: Self._dateFormatter.string(from: lastOpened))
			} else {
				_infoCell(.localized("آخر مرة انفتح"), desc: .localized("ما انفتح بعد"))
			}
			if
				let appDirectory = Storage.shared.getAppDirectory(for: app),
				let minimumOS = Bundle(url: appDirectory)?.minimumOSVersion
			{
				_infoCell(.localized("أقل iOS مطلوب"), desc: minimumOS)
			}
		}
	}

	@ViewBuilder
	private var _certSection: some View {
		if let cert = _certificate {
			NBSection(.localized("الشهادة")) {
				CertificatesCellView(cert: cert)
				if let expiration = cert.expiration {
					let info = expiration.expirationInfo()
					_infoCell(.localized("تنتهي"), desc: Self._dateFormatter.string(from: expiration))
						.foregroundStyle(info.color)
				}
			}
		} else {
			NBSection(.localized("الشهادة")) {
				Text(.localized("هالتطبيق ما موقع بعد — وقّعه حتى يشتغل على الآيفون."))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}
	}

	@ViewBuilder
	private func _infoCell(_ title: String, desc: String) -> some View {
		LabeledContent(title) {
			Text(desc)
		}
		.copyableText(desc)
	}

	// MARK: File size

	/// Measures the app bundle's real size on disk, off the main
	/// thread, and formats it the same way the Reset screen does.
	private func _measuredFileSizeText() async -> String {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else {
			return .localized("غير معروف")
		}
		let size = await Task.detached(priority: .userInitiated) {
			Self._directorySize(at: appDirectory)
		}.value
		return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
	}

	private static func _directorySize(at url: URL) -> Int {
		let fileManager = FileManager.default
		guard let enumerator = fileManager.enumerator(
			at: url,
			includingPropertiesForKeys: [.fileSizeKey],
			options: [.skipsHiddenFiles]
		) else {
			return 0
		}
		var total = 0
		for case let fileURL as URL in enumerator {
			if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
				total += size
			}
		}
		return total
	}
}
