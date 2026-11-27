//
//  ValueEditorInjector.swift
//  Zenith
//
//  Zenith v2.12, item 24 (#120): محرر القيم — in-game value search
//  & edit. The editor itself is a small injected dylib (see
//  Resources/ZenithValueEditor.m): a constructor-only dylib that
//  opens a floating planet button above the game, which opens the
//  search / refine / edit / freeze / saved-list menu. Inside the
//  game process it can read and write the game's own memory
//  (mach_vm_region + vm_read / vm_write) — a separate app could
//  never do that, the sandbox forbids it.
//
//  The injection itself is NOT new code: TweakHandler already
//  copies a .dylib into Frameworks and calls Zsign.injectDyLib
//  (LC_LOAD_DYLIB) on the main executable, and SigningHandler
//  already runs it for every file in Options.injectionFiles
//  before re-signing (SigningHandler.modify() → _inject, gated on
//  `!_options.injectionFiles.isEmpty`). This helper only stages
//  the Value Editor dylib into that existing list.
//
//  A build step compiles Resources/ZenithValueEditor.m into a
//  bundled ZenithValueEditor.dylib, so the toggle stages it
//  directly with no file picker: Bundle.main finds it and it
//  goes straight into Options.injectionFiles. Bringing your own
//  Value Editor .dylib still works as a fallback — any dylib
//  with "valueeditor" in its file name can be picked and staged
//  the same way, e.g. in a build where the compile step did not
//  run and no bundled dylib is present.
//
//  No Options field is added: staged state is derived from
//  Options.injectionFiles, so deleting the dylib from the list
//  also turns the editor off. No SigningHandler.modify() hook is
//  needed either — the existing injection call already covers
//  every file in injectionFiles, including this one.
//

import Foundation

// MARK: - ValueEditorInjector

enum ValueEditorInjector {
	/// Name of the compiled editor dylib. A build step compiles
	/// Resources/ZenithValueEditor.m into this bundled dylib.
	static let bundledDylibName = "ZenithValueEditor"

	/// The bundled editor dylib shipped in this build.
	/// Nil only in a build where the compile step did not run.
	static var bundledDylibURL: URL? {
		Bundle.main.url(forResource: bundledDylibName, withExtension: "dylib")
	}

	/// A Value Editor dylib is recognised by name: the bundled
	/// "ZenithValueEditor.dylib", or any user-supplied dylib with
	/// "valueeditor" in its file name.
	static func isValueEditorDylib(_ url: URL) -> Bool {
		let name = url.lastPathComponent.lowercased()
		return name.contains("valueeditor") || name.contains("value-editor")
	}

	/// True when a Value Editor dylib is staged for injection.
	static func isStaged(in options: Options) -> Bool {
		options.injectionFiles.contains(where: isValueEditorDylib)
	}

	/// The staged Value Editor dylibs (usually one).
	static func stagedFiles(in options: Options) -> [URL] {
		options.injectionFiles.filter(isValueEditorDylib)
	}

	/// Removes every staged Value Editor dylib from the injection
	/// list, and deletes the stored copy. Other injected tweaks
	/// are untouched.
	static func unstage(from options: inout Options) {
		for url in stagedFiles(in: options) {
			FileManager.default.deleteStored(url) { _ in }
			if let index = options.injectionFiles.firstIndex(where: { $0 == url }) {
				options.injectionFiles.remove(at: index)
			}
		}
	}
}
