//
//  GuestImportView.swift
//  Zenith
//
//  Phase 1 container — the import screen. An ADDITIONAL way a
//  Library app becomes runnable (from the passport's container
//  action): the user picks import-time patches (custom name +
//  the shared modding sections), then one button converts the
//  app into a guest (extract → patch → sign with the host
//  certificate) and the row becomes "Open inside Zenith".
//  NOTE (additive-only re-scope): this does NOT replace the
//  old signing screen — SigningView stays exactly as v2.13,
//  reachable from the passport's Sign button as before.
//
//  The options here start from a CLEAN copy
//  (Options.defaultOptions + the remembered display name for
//  this app only) — never the shared signing options — so a
//  stale staging from an earlier signing session can never
//  leak into an import. Stagings made on this screen live in
//  this copy and are discarded with the sheet, exactly like
//  the signing screen's temporary options.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct GuestImportView: View {
	var app: AppInfoPresentable

	@Environment(\.dismiss) private var _dismiss

	@State private var _options: Options
	@State private var _report: ModdabilityReport?
	@State private var _checkFailed = false
	@State private var _displayNameText: String
	@State private var _isImporting = false
	@State private var _progress: Double = 0
	@State private var _statusKey: String = "جارٍ الاستيراد..."
	@State private var _errorMessage: String?
	@State private var _isErrorPresenting = false
	@State private var _importedResult: ZenithGuestImporter.Result?
	/// iOS-compat warning shown before importing starts (set by _startImport).
	@State private var _isCompatAlertPresenting = false
	@State private var _compatMinimumOS = ""
	@State private var _compatDeviceOS = ""

	init(app: AppInfoPresentable) {
		self.app = app
		var initial = Options.defaultOptions
		// Only the remembered display name carries over from
		// the shared options — everything else starts clean.
		initial.displayNames = OptionsManager.shared.options.displayNames
		if let name = app.name, let remembered = initial.displayNames[name] {
			initial.appName = remembered
		}
		self._options = State(initialValue: initial)
		self._displayNameText = State(initialValue: initial.appName ?? app.name ?? "")
	}

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("استورد التطبيق"), displayMode: .inline) {
			Form {
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

				NBSection(.localized("Customization")) {
					CustomDisplayNameField(
						app: app,
						displayNameText: $_displayNameText,
						temporaryOptions: $_options
					)
				}

				GuestPatchSectionsView(
					app: app,
					options: $_options,
					report: $_report,
					checkFailed: $_checkFailed
				)

				if _isImporting {
					NBSection(.localized("استورد التطبيق")) {
						ProgressView(value: _progress)
						Text(.localized(_statusKey))
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				}

				if let result = _importedResult {
					NBSection(.localized("استورد التطبيق")) {
						Text(.localized("تم الاستيراد — افتح التطبيق من المكتبة."))
						if result.skippedDebCount > 0 {
							Text(verbatim: .localized("تم تخطي %lld ملفات deb — ما تنضاف بهالطريقة.", arguments: result.skippedDebCount))
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
						Button(.localized("Dismiss")) {
							_dismiss()
						}
					}
				}
			}
			.scrollContentBackground(.hidden)
			.background(Color.clear)
			.starfieldBackground()
			.listRowBackground(Color.clear)
			.safeAreaInset(edge: .bottom) { _bottomBar }
			.toolbar {
				NBToolbarButton(role: .close)
			}
			.disabled(_isImporting)
			.alert(.localized("ما قدرت أستورد هالتطبيق"), isPresented: $_isErrorPresenting) {
				Button(.localized("Dismiss"), role: .cancel) { }
			} message: {
				Text(_errorMessage ?? "")
			}
			.alert(.localized("هالتطبيق يحتاج iOS أحدث"), isPresented: $_isCompatAlertPresenting) {
				Button(.localized("إلغاء"), role: .cancel) { }
				Button(.localized("استورد على أي حال")) {
					_startImport(confirmed: true)
				}
			} message: {
				Text(verbatim: .localized("هالتطبيق يحتاج iOS %@ على الأقل، وجهازك عليه iOS %@. ممكن ما يشتغل بعد الاستيراد.", arguments: _compatMinimumOS, _compatDeviceOS))
			}
		}
	}

	// MARK: Bottom bar (same shape as the signing screen's:
	// a safe-area inset bar, never an overlay, so no row can
	// slide under the button).
	private var _bottomBar: some View {
		Button {
			_startImport()
		} label: {
			NBSheetButton(title: .localized("استورد التطبيق"), style: .prominent)
		}
		.buttonStyle(ZenithPressButtonStyle())
		.padding(.horizontal, 16)
		.padding(.top, 12)
		.padding(.bottom, 12)
		.background(Color.black)
		.disabled(_isImporting || _importedResult != nil)
	}

	// MARK: Import
	private func _startImport(confirmed: Bool = false) {
		// Warn when the app needs a newer iOS than this device
		// runs. The user can still proceed — the warning is
		// advice, not a block (same as the old signing flow).
		if !confirmed {
			switch IOSCompatValidator.check(app: app) {
			case .requiresNewer(let minimumOS, let deviceOS):
				_compatMinimumOS = minimumOS
				_compatDeviceOS = deviceOS
				_isCompatAlertPresenting = true
				return
			case .compatible, .unknown:
				break
			}
		}

		_isImporting = true
		_errorMessage = nil
		_isErrorPresenting = false
		_importedResult = nil
		_progress = 0
		_statusKey = "جارٍ الاستيراد..."

		let options = _options
		Task {
			do {
				let result = try await ZenithGuestImporter.importGuest(from: app, options: options) { progress, stage in
					_progress = progress
					_statusKey = stage.statusKey
				}
				await MainActor.run {
					_isImporting = false
					_importedResult = result
				}
			} catch {
				// The Help Center shows this as the last error,
				// same as the old signing flow.
				ZenithLastError.record(error)
				let message = error.localizedDescription
				await MainActor.run {
					_isImporting = false
					_errorMessage = message
					_isErrorPresenting = true
				}
			}
		}
	}
}
