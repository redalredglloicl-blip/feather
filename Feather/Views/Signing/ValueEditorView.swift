//
//  ValueEditorView.swift
//  Zenith
//
//  Zenith v2.12, item 24 (#120): محرر القيم — in-game value search
//  & edit. Section 1 "تعديل الألعاب", FIRST row.
//
//  The editor is a small injected dylib (Resources/
//  ZenithValueEditor.m, staged into Options.injectionFiles) that
//  runs INSIDE the game, where it can read and write the game's
//  own memory: search for an exact value (integer / float /
//  double), refine it after the value changes in-game, edit the
//  found address, freeze it so it stays, and keep a saved list
//  per game. Injection uses the existing TweakHandler +
//  Zsign.injectDyLib path — the same general tweak-injection
//  mechanism as every other staged dylib — so no new signing
//  code is needed, and no Options field is added (staged state
//  is derived from Options.injectionFiles, like the FPS counter).
//
//  HONEST LIMITS, stated in the view, never faked:
//  * A build step compiles Resources/ZenithValueEditor.m into a
//    bundled ZenithValueEditor.dylib, so the toggle stages it
//    directly with no file picker. Only in a build where that
//    compile step did not run (no bundled dylib found) does the
//    view say the file was not found and offer the file picker
//    so the user can bring their own Value Editor .dylib. The
//    toggle only stays on while a real dylib is staged.
//  * Offline games ONLY: values the game checks against a server
//    cannot be changed from the phone, and the view says so.
//  * If the game's anti-tamper blocks the injection (the menu
//    never appears, or the game crashes on launch), the view says
//    so plainly and points at the backup: restore the original
//    from the backup and sign again without the editor.
//
//  The view is offered only when the moddability check found local
//  files — same gate as the FPS counter — because the editor is an
//  offline-games-only modding tool.
//
//  MARK: - ValueEditorView
//  MARK: - ValueEditorRowLabel
//
//  The coordinator drops the row into section 1 "تعديل الألعاب"
//  on the signing screen, FIRST, before the other game rows:
//
//    NavigationLink {
//        ValueEditorView(options: $_temporaryOptions, report: _moddabilityReport)
//    } label: {
//        ValueEditorRowLabel()
//    }
//    .zenithGlassCard(cornerRadius: 12)
//    .padding(.vertical, 6)
//    .listRowSeparator(.hidden)
//
//  SigningView.swift is NOT edited by this file.
//

import SwiftUI
import NimbleViews

// MARK: - ValueEditorView

struct ValueEditorView: View {
	@Binding var options: Options
	/// The shared check result (filled in by ModdingCheckView).
	/// Nil while the check is still running.
	var report: ModdabilityReport?

	@State private var _valueEditorOn = false
	@State private var _isAddingPresenting = false

	private var _isOffered: Bool {
		report?.verdict == .likelyModdable
	}

	private var _bundledAvailable: Bool {
		ValueEditorInjector.bundledDylibURL != nil
	}

	var body: some View {
		NBList(.localized("Value Editor")) {
			NBSection(.localized("Value Editor")) {
				if report == nil {
					Text(.localized("Checking if this game can be modded…"))
						.font(.footnote)
						.foregroundColor(.secondary)
				} else if !_isOffered {
					Text(.localized("Value Editor is not offered for this game — no local files were found, so it is probably server-verified."))
						.font(.footnote)
						.foregroundColor(.secondary)
				} else {
					_offeredContent
				}
			}

			NBSection(.localized("Value Editor")) {
				Text(.localized("Offline games only — values checked by a server cannot be changed from your phone."))
					.font(.footnote)
					.foregroundColor(.secondary)
				Text(.localized("If the menu never appears, or the game crashes on launch, the game's protection blocked it."))
					.font(.footnote)
					.foregroundColor(.secondary)
				Text(.localized("Restore the original from your backup and sign again without this."))
					.font(.footnote)
					.foregroundColor(.secondary)
			}
		}
		.onAppear {
			_valueEditorOn = ValueEditorInjector.isStaged(in: options)
		}
		.onChange(of: options.injectionFiles) { _ in
			_valueEditorOn = ValueEditorInjector.isStaged(in: options)
		}
		.sheet(isPresented: $_isAddingPresenting, onDismiss: {
			// Picking nothing leaves nothing staged: the toggle
			// must not stay on with no dylib behind it.
			if !ValueEditorInjector.isStaged(in: options) {
				_valueEditorOn = false
			}
		}) {
			FileImporterRepresentableView(
				allowedContentTypes: [.dylib, .deb],
				allowsMultipleSelection: true,
				onDocumentsPicked: { urls in
					guard !urls.isEmpty else { return }

					for url in urls {
						// Only a Value Editor dylib belongs here: a
						// general tweak picked by mistake must not
						// be staged as the editor.
						guard ValueEditorInjector.isValueEditorDylib(url) else { continue }
						FileManager.default.moveAndStore(url, with: "ZenithValueEditor") { url in
							options.injectionFiles.append(url)
						}
					}
				}
			)
			.ignoresSafeArea()
		}
	}

	@ViewBuilder
	private var _offeredContent: some View {
		Text(.localized("Search for a value inside the game and change it."))
			.font(.footnote)
			.foregroundColor(.secondary)

		Text(.localized("How it works"))
			.font(.footnote)
			.fontWeight(.semibold)
			.padding(.top, 4)
		Group {
			Text(.localized("1. Open the game and note the value you want to change, like your coins."))
			Text(.localized("2. Search for that number in the menu."))
			Text(.localized("3. Play a little so the value changes, then search again to narrow the results."))
			Text(.localized("4. Edit the value you found, or freeze it so it stays."))
		}
		.font(.footnote)
		.foregroundColor(.secondary)

		Text(.localized("The menu collapses to a small floating planet button — drag it to any edge, tap it to reopen."))
			.font(.footnote)
			.foregroundColor(.secondary)
		Text(.localized("Your saved values live inside the game, in the menu's saved list."))
			.font(.footnote)
			.foregroundColor(.secondary)

		Toggle(isOn: $_valueEditorOn) {
			Text(.localized("Enable Value Editor"))
		}
		.onChange(of: _valueEditorOn) { isOn in
			if isOn {
				_turnOn()
			} else {
				ValueEditorInjector.unstage(from: &options)
			}
		}

		if ValueEditorInjector.isStaged(in: options) {
			Text(.localized("Value Editor staged — will be injected when you sign."))
				.font(.caption)
				.foregroundColor(.secondary)
			ForEach(ValueEditorInjector.stagedFiles(in: options), id: \.absoluteString) { tweak in
				_file(tweak: tweak)
			}
		} else if _bundledAvailable {
			Text(.localized("Value Editor is included in this build."))
				.font(.caption)
				.foregroundColor(.secondary)
		} else {
			// Fallback for a build where the compile step did not
			// run and no bundled dylib was found: say so plainly
			// and offer the file picker as a bring-your-own
			// option. In the normal built app the bundled dylib
			// is present and this branch is never shown.
			Text(.localized("Value Editor file was not found in this build."))
				.font(.footnote)
				.foregroundColor(.secondary)
			Text(.localized("Pick a Value Editor .dylib file."))
				.font(.caption)
				.foregroundColor(.secondary)
			Text(.localized("The file name must contain “valueeditor”."))
				.font(.caption)
				.foregroundColor(.secondary)
			Button {
				_isAddingPresenting = true
			} label: {
				Label {
					Text(.localized("Add Value Editor File"))
				} icon: {
					Image(systemName: "plus")
				}
			}
			.buttonStyle(ZenithPressButtonStyle())
		}
	}

	/// Turning the toggle on stages the bundled dylib shipped in
	/// this build; only if no bundled dylib is found (the
	/// compile step did not run) does it open the file picker so
	/// the user can bring their own editor dylib.
	private func _turnOn() {
		if let bundled = ValueEditorInjector.bundledDylibURL {
			FileManager.default.moveAndStore(bundled, with: "ZenithValueEditor") { url in
				options.injectionFiles.append(url)
			}
		} else {
			_isAddingPresenting = true
		}
	}

	@ViewBuilder
	private func _file(tweak: URL) -> some View {
		Label(tweak.lastPathComponent, systemImage: "folder.fill")
			.lineLimit(2)
			.frame(maxWidth: .infinity, alignment: .leading)
			.swipeActions(edge: .trailing, allowsFullSwipe: true) {
				_fileActions(tweak: tweak)
			}
			.contextMenu {
				_fileActions(tweak: tweak)
			}
	}

	@ViewBuilder
	private func _fileActions(tweak: URL) -> some View {
		Button(role: .destructive) {
			FileManager.default.deleteStored(tweak) { url in
				if let index = options.injectionFiles.firstIndex(where: { $0 == url }) {
					options.injectionFiles.remove(at: index)
				}
			}
		} label: {
			Label {
				Text(.localized("Delete"))
			} icon: {
				Image("icon-delete")
					.resizable()
					.scaledToFit()
					.frame(width: 20, height: 20)
			}
		}
	}
}

// MARK: - ValueEditorRowLabel

/// The signing-screen row for item 24 (#120): the title with its
/// 1–2 line Iraqi explanation underneath, per Reda's rule. The
/// coordinator uses this as the NavigationLink label.
struct ValueEditorRowLabel: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(.localized("Value Editor"))
				.font(.headline)
			Text(.localized("Value Editor Row Description"))
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(2)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
