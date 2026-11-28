
//
//  UnsignedValueEditorInjector.swift
//  Zenith
//
//  Zenith v2.38 Part B: "إضافة محرر القيم للعبة" — the Value
//  Editor for UNSIGNED games, straight from the Library
//  long-press menu. No signing, no certificate, no Apple ID:
//  the output is a modified, UNSIGNED .ipa that the user
//  shares (or imports back and signs later, like any IPA).
//
//  NOTHING here is a new injection mechanism. It reuses, in
//  order, the exact machinery the signing flow already uses:
//  * ValueEditorInjector.bundledDylibURL — the bundled
//    ZenithValueEditor.dylib the build step compiles from
//    Resources/ZenithValueEditor.m (same dylib the signing
//    screen stages into Options.injectionFiles).
//  * TweakHandler — copies the dylib into Frameworks and calls
//    Zsign.injectDyLib (LC_LOAD_DYLIB) on the main executable,
//    exactly as SigningHandler.modify() does via _inject.
//    ElleKit rides along exactly as it does on the signing
//    path (TweakHandler._checkEllekit adds it for any injection
//    into an app without CydiaSubstrate) — the editor dylib
//    itself has no Substrate dependency, but the bundle it
//    lands in is the same one signing produces.
//  * ArchiveHandler's re-package step — Payload/<name>.app
//    zipped to an .ipa with Zip.zipFiles.
//  The only differences from signing are the two the feature
//  needs: no SigningHandler / ZsignHandler / certificate is
//  touched at all, and the stale _CodeSignature +
//  embedded.mobileprovision are stripped from the copy first
//  (the same strip SigningHandler._removePresetFiles does),
//  so the IPA is honestly unsigned instead of carrying a
//  signature that no longer matches the modified binary.
//
//  The modified IPA is stored in Documents/Archives (the same
//  directory ArchiveHandler exports IPAs to) and its path is
//  recorded in LibraryPrefs (ValueEditorGame), which is what
//  the Home section "الألعاب المضاف لها محرر القيم" lists.
//  The Library entry itself is never modified: the original
//  game stays exactly as it was, signed or unsigned.
//

import Foundation
import Zip
import OSLog

enum UnsignedValueEditorInjector {
	enum InjectionError: Error, LocalizedError {
		case noBundledDylib
		case appNotFound
		case injectionFailed
		case archiveFailed

		var errorDescription: String? {
			switch self {
			case .noBundledDylib:
				"Value Editor file was not found in this build."
			case .appNotFound:
				"Unable to locate bundle path."
			case .injectionFailed:
				"Value Editor was not injected into the game."
			case .archiveFailed:
				"Could not build the modified IPA file."
			}
		}
	}

	/// Injects the bundled Value Editor dylib into a COPY of the
	/// game's .app and re-packages it as a new, unsigned .ipa.
	/// The original Library entry is never touched. Returns the
	/// modified IPA file URL (Documents/Archives).
	static func inject(into app: AppInfoPresentable) async throws -> URL {
		guard let dylibURL = ValueEditorInjector.bundledDylibURL else {
			throw InjectionError.noBundledDylib
		}
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else {
			throw InjectionError.appNotFound
		}

		let fileManager = FileManager.default
		let workDir = fileManager.temporaryDirectory
			.appendingPathComponent("ZenithValueEditor_\(UUID().uuidString)", isDirectory: true)
		let payloadDir = workDir.appendingPathComponent("Payload", isDirectory: true)
		let appCopy = payloadDir.appendingPathComponent(appDirectory.lastPathComponent)

		do {
			try fileManager.createDirectory(at: payloadDir, withIntermediateDirectories: true)
			try fileManager.copyItem(at: appDirectory, to: appCopy)

			// The old signature no longer matches the modified
			// binary — strip it, like SigningHandler does before
			// re-signing, so the IPA is honestly unsigned.
			try fileManager.removeFileIfNeeded(at: appCopy.appendingPathComponent("_CodeSignature"))
			try fileManager.removeFileIfNeeded(at: appCopy.appendingPathComponent("embedded.mobileprovision"))

			// REUSE: the signing flow's injection, with an
			// injection list of exactly one file — the bundled
			// Value Editor dylib. No SigningHandler, no cert.
			var options = OptionsManager.shared.options
			options.injectionFiles = [dylibURL]
			let handler = TweakHandler(app: appCopy, options: options)
			try await handler.getInputFiles()

			let injectedDylib = appCopy
				.appendingPathComponent("Frameworks")
				.appendingPathComponent(dylibURL.lastPathComponent)
			guard fileManager.fileExists(atPath: injectedDylib.path) else {
				throw InjectionError.injectionFailed
			}

			// REUSE: ArchiveHandler's re-package step —
			// Payload/<name>.app zipped to an .ipa.
			let zipURL = workDir.appendingPathComponent("ValueEditor.zip")
			try await Zip.zipFiles(
				paths: [payloadDir],
				zipFilePath: zipURL,
				password: nil,
				compression: ZipCompression.allCases[ArchiveHandler.getCompressionLevel()],
				progress: { _ in }
			)
			guard fileManager.fileExists(atPath: zipURL.path) else {
				throw InjectionError.archiveFailed
			}

			let baseName = _sanitized(app.name ?? appDirectory.deletingPathExtension().lastPathComponent)
			let fileName = "\(baseName)_ValueEditor_\(Int(Date().timeIntervalSince1970)).ipa"
			let destination = fileManager.archives.appendingPathComponent(fileName)
			try fileManager.createDirectoryIfNeeded(at: fileManager.archives)
			try fileManager.moveItem(at: zipURL, to: destination)
			try? fileManager.removeItem(at: workDir)
			Logger.misc.info("Value Editor injected (unsigned) into \(baseName), IPA at \(destination.path)")
			return destination
		} catch {
			try? fileManager.removeItem(at: workDir)
			throw error
		}
	}

	/// File-safe name: alphanumerics plus - _ . only, anything
	/// else becomes _. Never empty.
	private static func _sanitized(_ name: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
		let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
		let result = String(cleaned)
		return result.isEmpty ? "Game" : result
	}
}
