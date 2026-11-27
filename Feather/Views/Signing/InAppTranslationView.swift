
//
//  InAppTranslationView.swift
//  Zenith
//
//  Zenith v2.12, item 22 (#79): in-app translation at signing
//  time — the LAST item of section 2 "تعديل التطبيقات" on the
//  signing screen, after #64.
//
//  The screen scans the imported .app for bundled localization
//  tables (*.lproj/*.strings) and lets the user type their own
//  translation for each string, into one target language. The
//  staged edits live in Options.translationPlan and are written
//  into the copied .app by AppTranslationApplier at signing
//  time, before re-signing. If the app has no .strings tables,
//  the screen says so plainly instead of showing a fake
//  translator. There is NO machine translation here — Zenith has
//  no cloud translation service and no translation engine wired
//  in — and the screen says so.
//
//  The runtime overlay (a floating button inside the signed app
//  that switches which bundled .lproj the app reads) is staged
//  through Options.injectionFiles, exactly like the FPS overlay:
//  a build step compiles Resources/ZenithTranslateOverlay.m into
//  a bundled ZenithTranslate.dylib and the toggle stages it
//  directly with no file picker. Only in a build where that
//  compile step did not run does the screen say the file was not
//  found and offer the picker for a user-supplied .dylib.
//
//  WIRING (coordinator): drop the row into section 2
//  "تعديل التطبيقات" on the signing screen as its LAST item,
//  after #64:
//
//    InAppTranslationRowView(app: app, options: $_temporaryOptions)
//
//  The coordinator must also add `translationPlan:
//  TranslationPlan` to Options (OptionsManager.swift) with a
//  `TranslationPlan(targetLanguageCode: "ar", edits: [])`
//  default, and call AppTranslationApplier from
//  SigningHandler.modify() — see the hooks in
//  AppTranslationHandler.swift. SigningView.swift is NOT edited
//  by this file.
//

import SwiftUI
import NimbleViews

// MARK: - Row

/// The signing screen's section 2 row for item 22 (#79): title
/// with a one-to-two-line Iraqi-dialect explanation directly
/// underneath it, opening the translation screen.
struct InAppTranslationRowView: View {
	let app: AppInfoPresentable

	@Binding var options: Options

	// MARK: Body
	var body: some View {
		NavigationLink {
			InAppTranslationView(app: app, options: $options)
		} label: {
			VStack(alignment: .leading, spacing: 4) {
				Text(.localized("In-App Translation"))
					.font(.subheadline)
				Text(.localized("In-App Translation Row Explanation"))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}

// MARK: - View

struct InAppTranslationView: View {
	let app: AppInfoPresentable

	@Binding var options: Options

	@State private var _report: AppTranslationReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false
	@State private var _selectedTablePath = ""
	@State private var _overlayOn = false
	@State private var _isAddingPresenting = false

	/// The table the user is editing right now.
	private var _selectedTable: LocalizedStringsTable? {
		_report?.tables.first { $0.relativePath == _selectedTablePath }
			?? _report?.tables.first
	}

	/// True when the developer already ships a translation for
	/// the chosen target language — then there is nothing to
	/// type for it.
	private var _targetAlreadyBundled: Bool {
		guard let report = _report else { return false }
		return report.bundledLanguages.contains(options.translationPlan.targetLanguageCode)
	}

	// MARK: Body
	var body: some View {
		NBList(.localized("In-App Translation")) {
			NBSection(.localized("In-App Translation")) {
				Text(verbatim: .localized("In-App Translation Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized("No Machine Translation"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			if _appDirectoryMissing {
				NBSection(.localized("In-App Translation")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			} else if _isScanning {
				NBSection(.localized("In-App Translation")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
				}
			} else if let report = _report {
				if report.tables.isEmpty {
					NBSection(.localized("In-App Translation")) {
						Text(verbatim: .localized("No Localizable Text Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
						Text(verbatim: .localized("No Localizable Text Found Hint"))
							.font(.footnote)
							.foregroundStyle(.secondary)
						Text(verbatim: .localized("Hardcoded Text Cannot Be Translated"))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} else {
					_targetLanguageSection(report: report)
					_tableSection(report: report)
					if let table = _selectedTable {
						_stringsSection(table: table)
					}
					_overlaySection
					_notesSection
				}
			}
		}
		.starfieldBackground()
		.task { _scan() }
		.onAppear {
			_overlayOn = TranslationOverlayInjector.isStaged(in: options)
		}
		.onChange(of: options.injectionFiles) { _ in
			_overlayOn = TranslationOverlayInjector.isStaged(in: options)
		}
		.sheet(isPresented: $_isAddingPresenting, onDismiss: {
			// Picking nothing leaves nothing staged: the toggle
			// must not stay on with no dylib behind it.
			if !TranslationOverlayInjector.isStaged(in: options) {
				_overlayOn = false
			}
		}) {
			FileImporterRepresentableView(
				allowedContentTypes: [.dylib],
				onDocumentsPicked: { urls in
					guard let url = urls.first else { return }
					// Only a translation overlay belongs here: a
					// general tweak picked by mistake must not be
					// staged as the overlay.
					guard TranslationOverlayInjector.isTranslateDylib(url) else { return }
					FileManager.default.moveAndStore(url, with: "ZenithTranslate") { storedURL in
						options.injectionFiles.append(storedURL)
					}
				}
			)
			.ignoresSafeArea()
			.zenithSheetBackground()
		}
	}
}

// MARK: - Extension: View
extension InAppTranslationView {
	@ViewBuilder
	private func _targetLanguageSection(report: AppTranslationReport) -> some View {
		NBSection(.localized("Target Language")) {
			Picker(.localized("Target Language"), selection: Binding(
				get: { options.translationPlan.targetLanguageCode },
				set: { newCode in
					// One target language per signing run: the
					// staged edits belong to the old language,
					// and a value typed for it is not a
					// translation into the new one.
					options.translationPlan.targetLanguageCode = newCode
					options.translationPlan.edits.removeAll()
				}
			)) {
				ForEach(AppTranslationDetector.supportedTargetLanguages, id: \.code) { language in
					Text(verbatim: "\(language.name) (\(language.code))").tag(language.code)
				}
			}
			.pickerStyle(.menu)

			Text(verbatim: .localized("Switching Target Language Clears Edits"))
				.font(.footnote)
				.foregroundStyle(.secondary)

			if _targetAlreadyBundled {
				Text(verbatim: .localized("Translation Already Exists"))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized("Translation Already Exists Hint"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else if !options.translationPlan.edits.isEmpty {
				Text(verbatim: .localized(
					"Translation Staged Count",
					arguments: options.translationPlan.edits.count
				))
					.font(.footnote)
					.foregroundStyle(Color(hex: "#FFC778"))
			}

			if !report.bundledLanguages.isEmpty {
				Text(verbatim: .localized(
					"Bundled Languages",
					arguments: report.bundledLanguages.joined(separator: ", ")
				))
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}
	}

	@ViewBuilder
	private func _tableSection(report: AppTranslationReport) -> some View {
		NBSection(.localized("Strings Table")) {
			Picker(.localized("Strings Table"), selection: $_selectedTablePath) {
				ForEach(report.tables) { table in
					Text(verbatim: "\(table.relativePath) (\(table.keyCount))")
						.tag(table.relativePath)
				}
			}
			.pickerStyle(.menu)
		}
	}

	@ViewBuilder
	private func _stringsSection(table: LocalizedStringsTable) -> some View {
		NBSection(.localized("Strings Table")) {
			if _targetAlreadyBundled {
				Text(verbatim: .localized("Translation Already Exists Hint"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				ForEach(table.entries, id: \.key) { entry in
					_stringRow(table: table, key: entry.key, original: entry.value)
				}
				if table.keyCount > table.entries.count || (_report?.truncated == true && table.keyCount >= AppTranslationDetector.maxKeysPerTable) {
					Text(verbatim: .localized("More Strings Not Shown"))
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	@ViewBuilder
	private func _stringRow(table: LocalizedStringsTable, key: String, original: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(verbatim: original)
				.font(.subheadline)
			Text(verbatim: key)
				.font(.caption)
				.foregroundStyle(.secondary)
			TextField(
				.localized("Your Translation"),
				text: _translationBinding(table: table, key: key, original: original)
			)
			.font(.subheadline)
			.textFieldStyle(.roundedBorder)
			.disabled(_targetAlreadyBundled)
			if _stagedTranslation(table: table, key: key) != nil {
				Button(.localized("Clear Translation")) {
					options.translationPlan.edits.removeAll {
						$0.relativePath == table.relativePath && $0.key == key
					}
				}
				.font(.footnote)
				.foregroundStyle(.red)
			}
		}
	}

	@ViewBuilder
	private var _overlaySection: some View {
		NBSection(.localized("Tap To Translate Overlay")) {
			Text(verbatim: .localized("Tap To Translate Overlay Description"))
				.font(.footnote)
				.foregroundStyle(.secondary)

			Toggle(isOn: $_overlayOn) {
				Text(.localized("Tap To Translate Overlay"))
			}
			.onChange(of: _overlayOn) { isOn in
				if isOn {
					_turnOverlayOn()
				} else {
					TranslationOverlayInjector.unstage(from: &options)
				}
			}

			if TranslationOverlayInjector.isStaged(in: options) {
				Text(verbatim: .localized("Translation Overlay Staged"))
					.font(.footnote)
					.foregroundStyle(Color(hex: "#FFC778"))
				ForEach(TranslationOverlayInjector.stagedFiles(in: options), id: \.absoluteString) { tweak in
					Text(verbatim: tweak.lastPathComponent)
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} else if TranslationOverlayInjector.bundledDylibURL != nil {
				Text(verbatim: .localized("Translation Overlay Included"))
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				// Fallback for a build where the compile step did
				// not run and no bundled dylib was found: say so
				// plainly and offer the file picker as a
				// bring-your-own option. In the normal built app
				// the bundled dylib is present and this branch is
				// never shown.
				Text(verbatim: .localized("Translation Overlay Not Found"))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Text(verbatim: .localized("Pick Translation Overlay File"))
					.font(.footnote)
					.foregroundStyle(.secondary)
				Button {
					_isAddingPresenting = true
				} label: {
					Label {
						Text(.localized("Add Translation Overlay File"))
					} icon: {
						Image(systemName: "plus")
					}
				}
				.buttonStyle(ZenithPressButtonStyle())
			}
		}
	}

	@ViewBuilder
	private var _notesSection: some View {
		NBSection(.localized("In-App Translation")) {
			Text(verbatim: .localized("Hardcoded Text Cannot Be Translated"))
				.font(.footnote)
				.foregroundStyle(.secondary)
			Text(verbatim: .localized("Applied When You Sign"))
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}

	/// Turning the overlay on stages the bundled dylib shipped in
	/// this build; only if no bundled dylib is found (the
	/// compile step did not run) does it open the file picker so
	/// the user can bring their own overlay dylib.
	private func _turnOverlayOn() {
		if let bundled = TranslationOverlayInjector.bundledDylibURL {
			FileManager.default.moveAndStore(bundled, with: "ZenithTranslate") { url in
				options.injectionFiles.append(url)
			}
		} else {
			_isAddingPresenting = true
		}
	}

	private func _stagedTranslation(table: LocalizedStringsTable, key: String) -> TranslationEdit? {
		options.translationPlan.edits.first {
			$0.relativePath == table.relativePath && $0.key == key
		}
	}

	private func _translationBinding(table: LocalizedStringsTable, key: String, original: String) -> Binding<String> {
		Binding(
			get: {
				_stagedTranslation(table: table, key: key)?.translatedValue ?? ""
			},
			set: { newValue in
				options.translationPlan.edits.removeAll {
					$0.relativePath == table.relativePath && $0.key == key
				}
				// An empty field, or a value identical to the
				// original, is not a translation: stage nothing.
				guard !newValue.isEmpty, newValue != original else { return }
				options.translationPlan.edits.append(TranslationEdit(
					relativePath: table.relativePath,
					key: key,
					originalValue: original,
					translatedValue: newValue
				))
			}
		)
	}

	private func _scan() {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else {
			_appDirectoryMissing = true
			_isScanning = false
			return
		}
		Task.detached(priority: .userInitiated) {
			let report = AppTranslationDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop stale selections: only edits whose table
				// and key are still detected stay staged.
				let detectedKeys = Set(report.tables.flatMap { table in
					table.entries.map { table.relativePath + "#" + $0.key }
				})
				options.translationPlan.edits.removeAll {
					!detectedKeys.contains($0.relativePath + "#" + $0.key)
				}
				_report = report
				if let first = report.tables.first {
					_selectedTablePath = first.relativePath
				}
				_isScanning = false
			}
		}
	}
}
