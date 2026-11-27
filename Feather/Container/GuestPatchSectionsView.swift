//
//  GuestPatchSectionsView.swift
//  Zenith
//
//  Phase 1 container — the modding sections, hosted by the
//  guest-import screen.
//
//  Moved verbatim out of SigningView (same rows, same order,
//  same logic) so every file-based modding feature (IPA
//  browser, moddability check, backup, value editor,
//  local-file editor, graphics, FPS, the 13 app features)
//  is reachable from the import flow. NOTE (additive-only
//  re-scope): SigningView itself was restored to v2.13 and
//  keeps its OWN inline copy of these sections — this view is
//  used ONLY by GuestImportView now, not by the signing
//  screen. The moddability check still runs here on appear,
//  so the verdict exists before any sub-screen opens —
//  exactly as it did on the signing screen.
//
//  NOT moved here: the certificate picker, the custom icon
//  picker, the identifier / version editors, dylibs,
//  frameworks, entitlements and tweaks. Those are signing-time
//  features (the tweak/dylib ones need injection, which Phase 1
//  deliberately does not do); they stay reachable only from
//  SigningView, which stays exactly as v2.13.
//

import SwiftUI
import NimbleViews

// MARK: - Shared modding sections
struct GuestPatchSectionsView: View {
	var app: AppInfoPresentable
	@Binding var options: Options
	@Binding var report: ModdabilityReport?
	@Binding var checkFailed: Bool

	@State private var _isChecking = false

	var body: some View {
		_moddingOptions
			.onAppear {
				_runModdabilityCheckIfNeeded()
			}
			.onChange(of: report) { newValue in
				// Reset clears the shared report — re-run the
				// check here, otherwise every gated row stays
				// stuck on "checking" until the sheet is closed
				// and reopened.
				if newValue == nil {
					checkFailed = false
					_runModdabilityCheckIfNeeded()
				}
			}
	}

	// MARK: - Zenith v2.12: modding sections
	// Arrangement (Reda's order): the modding features must NOT
	// lie scattered along one long scroll. Each group lives
	// behind ONE row that opens its own screen (the متقدم /
	// عدّل / الخصائص pattern): "أدوات التعديل" (browser + check
	// + backup), "تعديل الألعاب" (the 4 game features),
	// "تعديل التطبيقات" (the 13 app features). Same rows, same
	// order, same logic — only the presentation changed from
	// inline sections to sub-screens. Every row shows its title
	// with a 1–2 line Iraqi explanation underneath it. Unpicked
	// slots are simply absent — nothing is shown for a feature
	// Reda did not pick.

	/// Zenith v2.13: the single "التعديل" section — three rows,
	/// each opening its own sub-screen with one modding group.
	private var _moddingOptions: some View {
		NBSection(.localized("Modding")) {
			NavigationLink {
				Form {
					_sharedModdingTools
				}
				// Zenith v2.8: stars on this pushed screen too.
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.starfieldBackground()
				.listRowBackground(Color.clear)
				.navigationTitle(.localized("Modding Tools"))
			} label: {
				Text(.localized("Modding Tools"))
			}
			NavigationLink {
				Form {
					_moddingSectionGames
				}
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.starfieldBackground()
				.listRowBackground(Color.clear)
				.navigationTitle(.localized("Mod Games"))
			} label: {
				Text(.localized("Mod Games"))
			}
			NavigationLink {
				Form {
					_moddingSectionApps
				}
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.starfieldBackground()
				.listRowBackground(Color.clear)
				.navigationTitle(.localized("Mod Apps"))
			} label: {
				Text(.localized("Mod Apps"))
			}
		}
	}

	/// Runs the moddability check for the screen hosting this
	/// view. Owned here (not by the check card) so the verdict
	/// is ready before any modding sub-screen opens. Same guard
	/// as the old signing screen: never twice at once, never
	/// when a verdict already exists.
	private func _runModdabilityCheckIfNeeded() {
		guard report == nil, !_isChecking else { return }
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else {
			// The app's files are not on disk: fail visibly
			// with a retry instead of leaving the card (and
			// every row gated on the report) spinning forever.
			checkFailed = true
			return
		}
		_isChecking = true
		Task {
			let result = await Task.detached(priority: .utility) {
				ModdabilityChecker.check(appDirectory: appDirectory)
			}.value
			report = result
			_isChecking = false
		}
	}

	/// Shared modding tools (used by both sections): browse the
	/// IPA's files, check whether the app can be modded, and keep
	/// a copy of the original before modding.
	private var _sharedModdingTools: some View {
		NBSection(.localized("Modding Tools")) {
			ModdingIPABrowserView(app: app)
			ModdingCheckView(
				app: app,
				report: $report,
				checkFailed: $checkFailed
			) {
				checkFailed = false
				_runModdabilityCheckIfNeeded()
			}
			BackupOriginalRowView(app: app)
		}
	}

	/// Section 1 — "تعديل الألعاب": game modding.
	private var _moddingSectionGames: some View {
		NBSection(.localized("Mod Games")) {
			NavigationLink {
				ValueEditorView(options: $options, report: $report)
			} label: {
				ValueEditorRowLabel()
			}
			ModFileEditorView(app: app, options: $options, report: report)
			GraphicsSettingsView(app: app, options: $options, report: report)
			FPSCounterView(options: $options, report: report)
		}
	}

	/// Section 2 — "تعديل التطبيقات": app modding.
	private var _moddingSectionApps: some View {
		NBSection(.localized("Mod Apps")) {
			_moddingRow(
				title: .localized("Remove Ads"),
				description: .localized("Remove Ads Row Description")
			) {
				RemoveAdsView(app: app, options: $options)
			}
			_moddingRow(
				title: .localized("Developer Menus"),
				description: .localized("Developer Menus Row Description")
			) {
				DevMenuView(app: app, options: $options)
			}
			_moddingRow(
				title: .localized("Remove Watermark"),
				description: .localized("Remove Watermark Row Description")
			) {
				RemoveWatermarkView(app: app, options: $options)
			}
			_moddingRow(
				title: .localized("Remove Export Limits"),
				description: .localized("Remove Export Limits Row Description")
			) {
				RemoveExportLimitsView(app: app, options: $options)
			}
			_moddingRow(
				title: .localized("Remove Subscription Screen"),
				description: .localized("Remove Subscription Screen Row Description")
			) {
				RemoveSubscriptionScreenView(app: app, options: $options)
			}
			_moddingRow(
				title: .localized("Stop Forced Updates"),
				description: .localized("Stop Forced Updates Row Description")
			) {
				StopForcedUpdatesView(app: app, options: $options)
			}
			_moddingRow(
				title: .localized("Change App Font"),
				description: .localized("Change App Font Row Description")
			) {
				ChangeAppFontView(app: app, options: $options)
			}
			_moddingRow(
				title: .localized("Speed Up Animations"),
				description: .localized("Speed Up Animations Row Description")
			) {
				AnimationSpeedView(app: app, options: $options)
			}
			NavigationLink {
				ChangeLocationView(app: app, options: $options)
			} label: {
				ChangeLocationRowLabel()
			}
			NavigationLink {
				GuestModeView(app: app, options: $options)
			} label: {
				GuestModeRowLabel()
			}
			NavigationLink {
				ForceDarkModeView(app: app, options: $options)
			} label: {
				ForceDarkModeRowLabel()
			}
			InAppTranslationRowView(app: app, options: $options)
			LiteVersionRowView(app: app, options: $options)
		}
	}

	/// A modding row: title on top, 1–2 line Iraqi explanation
	/// underneath it, in the row itself (Reda's standing rule).
	@ViewBuilder
	private func _moddingRow<V: View>(title: String, description: String, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
				Text(verbatim: description)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
		}
	}
}
