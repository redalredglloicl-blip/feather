//
//  ChangeAppFontView.swift
//  Zenith
//
//  Zenith v2.12, item 17 (#45): change an app's font at signing
//  time — item 10 of the "تعديل التطبيقات" section on the signing
//  screen, after #44.
//
//  The screen scans the imported .app for bundled font files
//  (.ttf / .otf) and the UIAppFonts entries in Info.plist, and
//  offers to replace each bundled font with a font file the user
//  supplies, before re-signing. The replacement keeps the
//  original file name, so UIAppFonts keeps working and no plist
//  edit is needed. The chosen replacements are staged in
//  Options.fontReplacements and applied by AppFontApplier at
//  signing time, before re-signing. The app does NOT ship fonts:
//  the user must bring the font file themselves. If the app has
//  no bundled font (it uses the system fonts), the screen says so
//  plainly instead of showing a fake toggle.
//
//  WIRING (coordinator): drop this view into the "تعديل
//  التطبيقات" section on the signing screen as item 10, after
//  #44:
//
//    NavigationLink(.localized("Change App Font")) {
//        ChangeAppFontView(
//            app: app,
//            options: $_temporaryOptions
//        )
//    }
//    .zenithGlassCard(cornerRadius: 12)
//    .padding(.vertical, 6)
//    .listRowSeparator(.hidden)
//
//  The coordinator must also add `fontReplacements:
//  [FontReplacement]` to Options (OptionsManager.swift) with a
//  `[]` default, and call AppFontApplier from
//  SigningHandler.modify() — see the hook in AppFontHandler.swift.
//

import SwiftUI
import UniformTypeIdentifiers
import NimbleViews

// MARK: - View
struct ChangeAppFontView: View {
	let app: AppInfoPresentable

	@Binding var options: Options

	@State private var _report: AppFontReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false
	@State private var _pickingFont: BundledFont?

	// MARK: Body
	var body: some View {
		NBList(.localized("Change App Font")) {
			NBSection(.localized("Change App Font")) {
				Text(verbatim: .localized("Change App Font Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			}

			if _appDirectoryMissing {
				NBSection(.localized("Change App Font")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			} else if _isScanning {
				NBSection(.localized("Change App Font")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			} else if let report = _report {
				if report.fonts.isEmpty {
					NBSection(.localized("Change App Font")) {
						Text(verbatim: .localized("No Bundled Fonts Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("No Bundled Fonts Hint"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("System Fonts Cannot Be Changed"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					}
				} else {
					NBSection(.localized("Bundled Fonts in This App")) {
						ForEach(report.fonts) { font in
							_fontRow(font)
						}
					}

					NBSection(.localized("Change App Font")) {
						Text(verbatim: .localized("Zenith Does Not Ship Fonts"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("Replaced When You Sign"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("System Fonts Cannot Be Changed"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					}
				}
			}
		}
		.starfieldBackground()
		.task { _scan() }
		.sheet(item: $_pickingFont) { font in
			FileImporterRepresentableView(
				allowedContentTypes: [.font],
				onDocumentsPicked: { urls in
					_pickingFont = nil
					guard let url = urls.first else { return }
					_pickFont(url, for: font)
				}
			)
			.ignoresSafeArea()
			.zenithSheetBackground()
		}
	}
}

// MARK: - Extension: View
extension ChangeAppFontView {
	@ViewBuilder
	private func _fontRow(_ font: BundledFont) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				VStack(alignment: .leading, spacing: 4) {
					Text(verbatim: font.fileName)
						.font(.subheadline)
					Text(verbatim: font.relativePath)
						.font(.caption)
						.foregroundStyle(.secondary)
					Text(verbatim: font.registeredInUIAppFonts
						? .localized("Font Registered")
						: .localized("Font Not Registered"))
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				Spacer()
			}

			if let replacement = options.fontReplacements.first(where: { $0.targetRelativePath == font.relativePath }) {
				HStack {
					Text(verbatim: replacement.sourceFileName)
						.font(.footnote)
					Spacer()
					Button(.localized("Cancel Font Replacement")) {
						options.fontReplacements.removeAll { $0.targetRelativePath == font.relativePath }
					}
					.font(.footnote)
					.foregroundStyle(.red)
				}
			} else {
				Button(.localized("Choose Font")) {
					_pickingFont = font
				}
				.font(.subheadline)
			}
		}
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
	}

	/// Stores the picked font file and stages it as the
	/// replacement for this bundled font. Only .ttf / .otf files
	/// are accepted — anything else the picker let through is
	/// ignored.
	private func _pickFont(_ url: URL, for font: BundledFont) {
		let ext = url.pathExtension.lowercased()
		guard ext == "ttf" || ext == "otf" else { return }
		FileManager.default.moveAndStore(url, with: "ZenithFont") { storedURL in
			options.fontReplacements.removeAll { $0.targetRelativePath == font.relativePath }
			options.fontReplacements.append(FontReplacement(
				targetRelativePath: font.relativePath,
				sourceFontURL: storedURL,
				sourceFileName: url.lastPathComponent
			))
		}
	}

	private func _scan() {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else {
			_appDirectoryMissing = true
			_isScanning = false
			return
		}
		Task.detached(priority: .userInitiated) {
			let report = AppFontDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only fonts still detected
				// stay selected.
				let detected = Set(report.fonts.map(\.relativePath))
				options.fontReplacements.removeAll { !detected.contains($0.targetRelativePath) }
				_report = report
				_isScanning = false
			}
		}
	}
}
