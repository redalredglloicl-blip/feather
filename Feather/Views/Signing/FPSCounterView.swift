//
//  FPSCounterView.swift
//  Zenith
//
//  Zenith v2.12, item 12 (#31): in-game FPS counter. Section 1
//  "تعديل الألعاب", position 7.
//
//  An overlay showing the game's frame rate while playing. The
//  overlay is a small injected dylib (Resources/ZenithFPSOverlay.m,
//  staged into Options.injectionFiles) that draws the rendered
//  frames per second as presented on screen. Injection uses the
//  existing TweakHandler + Zsign.injectDyLib path — the same path
//  as the mod menu — so no new signing code is needed.
//
//  A build step compiles Resources/ZenithFPSOverlay.m into a
//  bundled ZenithFPS.dylib, so the toggle stages it directly
//  with no file picker. Only in a build where that compile step
//  did not run (no bundled dylib found) does the view say the
//  file was not found and offer the file picker so the user can
//  bring their own FPS overlay .dylib. The toggle only stays on
//  while a real dylib is staged.
//
//  The view is offered only when the moddability check found local
//  files — same gate as the mod menu — because the counter is an
//  offline-games-only modding tool. What it measures is stated in
//  the view: rendered frames per second as presented on screen.
//
//  MARK: - FPSCounterView
//
//  The section-placeable card. The coordinator drops this view
//  into section 1 "تعديل الألعاب" on the signing screen, after
//  the integrity check (position 7) and before the ready-mod
//  import:
//
//    FPSCounterView(options: $_temporaryOptions, report: _moddingReport)
//
//  SigningView.swift is NOT edited by this file.
//

import SwiftUI
import NimbleViews

// MARK: - FPSCounterView

struct FPSCounterView: View {
	@Binding var options: Options
	/// The shared check result (filled in by ModdingCheckView).
	/// Nil while the check is still running.
	var report: ModdabilityReport?

	@State private var _fpsOn = false
	@State private var _isAddingPresenting = false

	private var _isOffered: Bool {
		report?.verdict == .likelyModdable
	}

	private var _bundledAvailable: Bool {
		FPSOverlayInjector.bundledDylibURL != nil
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(.localized("In-Game FPS Counter"))
				.font(.footnote)
				.fontWeight(.semibold)

			if report == nil {
				Text(.localized("Checking if this game can be modded…"))
					.font(.footnote)
					.foregroundColor(.secondary)
			} else if !_isOffered {
				Text(.localized("FPS overlay is not offered for this game — no local files were found, so it is probably server-verified."))
					.font(.footnote)
					.foregroundColor(.secondary)
			} else {
				_offeredContent
			}

			Text(.localized("FPS counters only work on offline games."))
				.font(.caption)
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.onAppear {
			_fpsOn = FPSOverlayInjector.isStaged(in: options)
		}
		.onChange(of: options.injectionFiles) { _ in
			_fpsOn = FPSOverlayInjector.isStaged(in: options)
		}
		.sheet(isPresented: $_isAddingPresenting, onDismiss: {
			// Picking nothing leaves nothing staged: the toggle
			// must not stay on with no dylib behind it.
			if !FPSOverlayInjector.isStaged(in: options) {
				_fpsOn = false
			}
		}) {
			FileImporterRepresentableView(
				allowedContentTypes: [.dylib, .deb],
				allowsMultipleSelection: true,
				onDocumentsPicked: { urls in
					guard !urls.isEmpty else { return }

					for url in urls {
						// Only an FPS overlay belongs here: a
						// general tweak picked by mistake must not
						// be staged as the FPS counter.
						guard FPSOverlayInjector.isFPSDylib(url) else { continue }
						FileManager.default.moveAndStore(url, with: "ZenithFPS") { url in
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
		Text(.localized("Show the game's frame rate while playing."))
			.font(.footnote)
			.foregroundColor(.secondary)
		Text(.localized("Shows the game's rendered frames per second, as presented on screen, in a small overlay while you play."))
			.font(.caption)
			.foregroundColor(.secondary)

		Toggle(isOn: $_fpsOn) {
			Text(.localized("Show FPS Counter"))
		}
			.onChange(of: _fpsOn) { isOn in
				if isOn {
					_turnOn()
				} else {
					FPSOverlayInjector.unstage(from: &options)
				}
			}

		if FPSOverlayInjector.isStaged(in: options) {
			Text(.localized("FPS overlay staged — will be injected when you sign."))
				.font(.caption)
				.foregroundColor(.secondary)
			ForEach(FPSOverlayInjector.stagedFiles(in: options), id: \.absoluteString) { tweak in
				_file(tweak: tweak)
			}
		} else if _bundledAvailable {
			Text(.localized("FPS overlay is included in this build."))
				.font(.caption)
				.foregroundColor(.secondary)
		} else {
			// Fallback for a build where the compile step did not
			// run and no bundled dylib was found: say so plainly
			// and offer the file picker as a bring-your-own
			// option. In the normal built app the bundled dylib
			// is present and this branch is never shown.
			Text(.localized("FPS overlay file was not found in this build."))
				.font(.footnote)
				.foregroundColor(.secondary)
			Text(.localized("Pick an FPS overlay .dylib file."))
				.font(.caption)
				.foregroundColor(.secondary)
			Button {
				_isAddingPresenting = true
			} label: {
				Label {
					Text(.localized("Add FPS Overlay File"))
				} icon: {
					Image(systemName: "plus")
				}
			}
			.buttonStyle(ZenithPressButtonStyle())
		}

		_preview
	}

	/// Turning the toggle on stages the bundled dylib shipped in
	/// this build; only if no bundled dylib is found (the
	/// compile step did not run) does it open the file picker so
	/// the user can bring their own overlay dylib.
	private func _turnOn() {
		if let bundled = FPSOverlayInjector.bundledDylibURL {
			FileManager.default.moveAndStore(bundled, with: "ZenithFPS") { url in
				options.injectionFiles.append(url)
			}
		} else {
			_isAddingPresenting = true
		}
	}

	/// A static preview of how the overlay looks in-game: a small
	/// dark pill with the frame rate. It measures nothing — it
	/// only shows the design. The real overlay is the injected
	/// dylib (Resources/ZenithFPSOverlay.m).
	@ViewBuilder
	private var _preview: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(.localized("Overlay Preview"))
				.font(.caption)
				.foregroundColor(.secondary)
			Text(verbatim: "FPS: 60")
				.font(.system(.footnote, design: .monospaced))
				.fontWeight(.semibold)
				.foregroundColor(.green)
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.background(Color.black.opacity(0.6))
				.clipShape(Capsule())
		}
		.padding(.top, 4)
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
