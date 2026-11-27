//
//  FPSOverlayInjector.swift
//  Zenith
//
//  Zenith v2.12, item 12 (#31): in-game FPS counter. The overlay
//  itself is a small injected dylib (see Resources/ZenithFPSOverlay.m):
//  a constructor-only dylib that opens a floating window and drives
//  it with CADisplayLink, so it shows the game's rendered frames
//  per second as presented on screen. It hooks nothing in the game.
//
//  The injection itself is NOT new code: TweakHandler already
//  copies a .dylib into Frameworks and calls Zsign.injectDyLib
//  (LC_LOAD_DYLIB) on the main executable, and SigningHandler
//  already runs it for every file in Options.injectionFiles
//  before re-signing. This helper only stages the FPS dylib into
//  that existing list.
//
//  HONEST LIMIT: the compiled ZenithFPS.dylib is bundled by a
//  build step that compiles Resources/ZenithFPSOverlay.m into
//  it, so the toggle stages it directly with no file picker:
//  Bundle.main finds it and it goes straight into
//  Options.injectionFiles. Bringing your own FPS overlay .dylib
//  still works as a fallback — any dylib with "fps" in its file
//  name can be picked and staged the same way, e.g. in a build
//  where the compile step did not run and no bundled dylib is
//  present. The view says so only in that missing-dylib case.
//
//  No Options field is added: staged state is derived from
//  Options.injectionFiles, so deleting the dylib from the mod-menu
//  list also turns the counter off.
//

import Foundation

// MARK: - FPSOverlayInjector

enum FPSOverlayInjector {
	/// Name of the compiled overlay dylib. A build step compiles
	/// Resources/ZenithFPSOverlay.m into this bundled dylib.
	static let bundledDylibName = "ZenithFPS"

	/// The bundled overlay dylib shipped in this build.
	/// Nil only in a build where the compile step did not run.
	static var bundledDylibURL: URL? {
		Bundle.main.url(forResource: bundledDylibName, withExtension: "dylib")
	}

	/// An FPS overlay dylib is recognised by name: the bundled
	/// "ZenithFPS.dylib", or any user-supplied dylib with "fps"
	/// in its file name.
	static func isFPSDylib(_ url: URL) -> Bool {
		url.lastPathComponent.lowercased().contains("fps")
	}

	/// True when an FPS overlay dylib is staged for injection.
	static func isStaged(in options: Options) -> Bool {
		options.injectionFiles.contains(where: isFPSDylib)
	}

	/// The staged FPS overlay dylibs (usually one).
	static func stagedFiles(in options: Options) -> [URL] {
		options.injectionFiles.filter(isFPSDylib)
	}

	/// Removes every staged FPS overlay dylib from the injection
	/// list, and deletes the stored copy. Other injected tweaks
	/// (mod menu, ...) are untouched.
	static func unstage(from options: inout Options) {
		for url in stagedFiles(in: options) {
			FileManager.default.deleteStored(url) { _ in }
			if let index = options.injectionFiles.firstIndex(where: { $0 == url }) {
				options.injectionFiles.remove(at: index)
			}
		}
	}
}
