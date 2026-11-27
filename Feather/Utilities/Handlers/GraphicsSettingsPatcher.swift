//
//  GraphicsSettingsPatcher.swift
//  Zenith
//
//  Zenith v2.12, item 11 (#29): unlock hidden graphics settings.
//  Scans the extracted .app for local graphics-quality config
//  (Info.plist aside — that is app metadata, handled by the signing
//  options — plus quality plists, JSON, Unity boot.config, Unreal
//  .ini files and other plain-text config) and finds gates keyed by
//  device model or capped quality / frame rate.
//
//  A gate is only reported when a concrete patch exists for it:
//  a numeric quality cap is raised, a "Low"/"Medium" quality is
//  raised to "High" (or "Ultra" when the file itself mentions it),
//  a frame-rate cap below 60 is raised to 60, and a device-model
//  restriction is removed. Anything already at max is not a gate,
//  and a game with no such config gets the honest "no hidden
//  graphics settings" verdict — never a fake toggle.
//
//  Patching reuses the existing staged-edit pipeline: patches are
//  staged as ModFileEdit values in Options.modFileEdits and applied
//  by SigningHandler.modify() (via ModFileEditor.apply) to the
//  copied .app before re-signing. No SigningHandler change needed.
//
//  Only local config can be patched. Quality locked by the game
//  server cannot be unlocked, and the UI says so.
//

import Foundation

// MARK: - Model

/// One patchable graphics gate found in a config file.
struct GraphicsGate: Codable, Equatable, Identifiable {
	var id: String { relativePath + "|" + keyPath }

	/// Path inside the .app bundle, e.g. `Data/boot.config`.
	var relativePath: String
	/// Key path inside the file: dotted path for plist/JSON
	/// (`QualitySettings.quality`), the raw key for ini/text
	/// files (`gfx-quality`).
	var keyPath: String
	var kind: Kind
	/// The value found in the file, as display text.
	var currentValue: String
	/// The value the patch writes. Empty for a device gate:
	/// the restriction is removed, not replaced.
	var patchedValue: String

	enum Kind: String, Codable {
		case qualityCap
		case deviceGate
		case frameRateCap
	}
}

/// The outcome of the graphics-settings scan.
struct GraphicsSettingsReport: Equatable {
	enum Verdict: Equatable {
		case gatesFound
		case noGates
	}

	var verdict: Verdict
	var gates: [GraphicsGate]
	/// Config files actually read during the scan.
	var scannedFiles: Int
}

// MARK: - Patcher

enum GraphicsSettingsPatcher {
	/// Safety caps so a huge bundle cannot stall the signing screen.
	static let maxScannedEntries = 20000
	static let maxFileBytes = 1_000_000

	/// Config extensions the scanner reads. The bundle's own
	/// Info.plist is excluded separately — it is app metadata,
	/// not game graphics config.
	static let configExtensions: Set<String> = [
		"plist", "json", "ini", "cfg", "config", "txt", "properties"
	]

	/// A staged patch result: files patched, and files skipped
	/// because the user already staged a hand edit for them.
	struct StageResult {
		var staged: [String]
		var skippedAlreadyEdited: [String]
	}

	// MARK: Scan

	/// Scans `appDirectory` (a `.app` bundle) for graphics gates.
	/// Synchronous — call from a background queue.
	static func scan(appDirectory: URL) -> GraphicsSettingsReport {
		var gates: [GraphicsGate] = []
		var scannedFiles = 0

		guard let enumerator = FileManager.default.enumerator(
			at: appDirectory,
			includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
			options: [.skipsHiddenFiles]
		) else {
			return GraphicsSettingsReport(verdict: .noGates, gates: [], scannedFiles: 0)
		}

		let appPath = appDirectory.path
		var scanned = 0

		for case let url as URL in enumerator {
			scanned += 1
			if scanned > maxScannedEntries { break }

			let relativePath = url.path.replacingOccurrences(of: appPath + "/", with: "")
			let firstComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
			if ["_CodeSignature", "Frameworks", "PlugIns", "Watch"].contains(firstComponent) {
				continue
			}
			if relativePath.contains(".lproj/") {
				continue
			}
			// The bundle's own Info.plist is app metadata, not
			// game graphics config.
			if relativePath == "Info.plist" {
				continue
			}

			let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
			guard values?.isRegularFile == true else { continue }
			guard (values?.fileSize ?? 0) <= maxFileBytes else { continue }

			let ext = url.pathExtension.lowercased()
			guard configExtensions.contains(ext) else { continue }

			guard let data = try? Data(contentsOf: url) else { continue }
			// A NUL byte means binary data, not config text — but
			// binary plists are real config too, and
			// PropertyListSerialization reads them, so the check
			// skips plist files.
			if ext != "plist" && data.prefix(4096).contains(0) {
				continue
			}

			scannedFiles += 1
			gates += _gates(in: data, relativePath: relativePath)
		}

		gates.sort { ($0.relativePath, $0.keyPath) < ($1.relativePath, $1.keyPath) }

		return GraphicsSettingsReport(
			verdict: gates.isEmpty ? .noGates : .gatesFound,
			gates: gates,
			scannedFiles: scannedFiles
		)
	}

	// MARK: Staging (into the existing modFileEdits pipeline)

	/// Builds the patched full text for the given gates in one
	/// file, reading the file fresh from `appDirectory`. Returns
	/// nil when the file cannot be read or patched.
	static func patchedText(for gates: [GraphicsGate], in appDirectory: URL) -> String? {
		guard let first = gates.first else { return nil }
		let relativePath = first.relativePath
		guard gates.allSatisfy({ $0.relativePath == relativePath }) else { return nil }
		guard let url = _resolvedURL(for: relativePath, in: appDirectory) else { return nil }
		guard let data = try? Data(contentsOf: url) else { return nil }

		switch URL(fileURLWithPath: relativePath).pathExtension.lowercased() {
		case "plist":
			return _patchedPlistText(data: data, gates: gates)
		case "json":
			return _patchedJSONText(data: data, gates: gates)
		default:
			guard let text = String(data: data, encoding: .utf8) else { return nil }
			return _patchedPlainText(text: text, gates: gates)
		}
	}

	/// Stages the selected gates as ModFileEdit values in
	/// `options`. A file the user already hand-edited (a staged
	/// edit whose text differs from what is on disk) is left
	/// untouched and reported in `skippedAlreadyEdited` — the
	/// patcher never overwrites the user's own edit.
	static func stage(
		gates: [GraphicsGate],
		into options: inout Options,
		appDirectory: URL
	) -> StageResult {
		var staged: [String] = []
		var skipped: [String] = []

		let byFile = Dictionary(grouping: gates, by: { $0.relativePath })
		for relativePath in byFile.keys.sorted() {
			let fileGates = byFile[relativePath] ?? []

			// Never overwrite a staged hand edit for this file.
			// When the file reads as text, a staged edit that
			// differs from disk is the user's own — unless it is
			// exactly this patch (re-staging is idempotent). When
			// the file does not read as text (binary plist), the
			// same rule applies against the patch text alone.
			if let existing = options.modFileEdits.first(where: { $0.relativePath == relativePath }) {
				let patched = patchedText(for: fileGates, in: appDirectory)
				if let diskText = _diskText(for: relativePath, in: appDirectory) {
					if existing.editedText != diskText && existing.editedText != patched {
						skipped.append(relativePath)
						continue
					}
				} else if existing.editedText != patched {
					skipped.append(relativePath)
					continue
				}
			}

			guard let newText = patchedText(for: fileGates, in: appDirectory) else {
				skipped.append(relativePath)
				continue
			}

			let edit = ModFileEdit(relativePath: relativePath, editedText: newText)
			if let index = options.modFileEdits.firstIndex(where: { $0.relativePath == relativePath }) {
				options.modFileEdits[index] = edit
			} else {
				options.modFileEdits.append(edit)
			}
			staged.append(relativePath)
		}

		return StageResult(staged: staged, skippedAlreadyEdited: skipped)
	}

	/// Removes the staged patch for the given files — but only
	/// when the staged text is exactly what the patcher produced,
	/// so a hand edit is never deleted by mistake.
	static func unstage(paths: [String], from options: inout Options, appDirectory: URL) {
		for relativePath in paths {
			guard let index = options.modFileEdits.firstIndex(where: { $0.relativePath == relativePath }) else {
				continue
			}
			let gates = _gatesForFile(relativePath, in: appDirectory)
			if let patched = patchedText(for: gates, in: appDirectory),
			   options.modFileEdits[index].editedText == patched {
				options.modFileEdits.remove(at: index)
			}
		}
	}

	/// True when the staged edit for `relativePath` is exactly the
	/// patch this patcher would produce for the gates in that file.
	static func isPatchStaged(for relativePath: String, in options: Options, appDirectory: URL) -> Bool {
		guard let staged = options.modFileEdits.first(where: { $0.relativePath == relativePath }) else {
			return false
		}
		let gates = _gatesForFile(relativePath, in: appDirectory)
		guard !gates.isEmpty else { return false }
		return staged.editedText == patchedText(for: gates, in: appDirectory)
	}

	// MARK: - Finding gates

	private struct _Candidate {
		var keyPath: String
		var keyLower: String
		var stringValue: String? = nil
		var intValue: Int? = nil
		var doubleValue: Double? = nil
	}

	private static func _gates(in data: Data, relativePath: String) -> [GraphicsGate] {
		let ext = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
		switch ext {
		case "plist":
			guard let top = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
				  let dict = top as? [String: Any] else {
				return []
			}
			var candidates: [_Candidate] = []
			_walkDict(dict, keyPath: [], into: &candidates)
			return _gates(from: candidates, fileText: nil, relativePath: relativePath)
		case "json":
			guard let top = try? JSONSerialization.jsonObject(with: data),
				  let dict = top as? [String: Any] else {
				return []
			}
			var candidates: [_Candidate] = []
			_walkDict(dict, keyPath: [], into: &candidates)
			return _gates(from: candidates, fileText: nil, relativePath: relativePath)
		default:
			guard let text = String(data: data, encoding: .utf8) else { return [] }
			let candidates = _textCandidates(in: text)
			return _gates(from: candidates, fileText: text, relativePath: relativePath)
		}
	}

	/// Re-scans one file from disk and returns its gates. Used to
	/// recognise a staged patch without keeping scan state.
	private static func _gatesForFile(_ relativePath: String, in appDirectory: URL) -> [GraphicsGate] {
		guard let url = _resolvedURL(for: relativePath, in: appDirectory),
			  let data = try? Data(contentsOf: url) else {
			return []
		}
		return _gates(in: data, relativePath: relativePath)
	}

	/// Walks nested dictionaries only. Array elements are skipped:
	/// patching inside arrays cannot address a key reliably.
	private static func _walkDict(
		_ dict: [String: Any],
		keyPath: [String],
		into candidates: inout [_Candidate]
	) {
		for (key, value) in dict {
			let path = keyPath + [key]
			switch value {
			case let string as String:
				candidates.append(_Candidate(
					keyPath: path.joined(separator: "."),
					keyLower: key.lowercased(),
					stringValue: string
				))
			case let number as NSNumber:
				// NSNumber bridges Bool too — a Bool is not a gate.
				if CFGetTypeID(number) == CFBooleanGetTypeID() {
					continue
				}
				let double = number.doubleValue
				if double == double.rounded() && abs(double) < 1_000_000 {
					candidates.append(_Candidate(
						keyPath: path.joined(separator: "."),
						keyLower: key.lowercased(),
						intValue: Int(double)
					))
				} else {
					candidates.append(_Candidate(
						keyPath: path.joined(separator: "."),
						keyLower: key.lowercased(),
						doubleValue: double
					))
				}
			case let nested as [String: Any]:
				_walkDict(nested, keyPath: path, into: &candidates)
			default:
				continue
			}
		}
	}

	/// One candidate per `key=value` / `key: value` line.
	private static func _textCandidates(in text: String) -> [_Candidate] {
		var candidates: [_Candidate] = []
		for rawLine in text.components(separatedBy: "\n") {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			guard !line.isEmpty else { continue }
			guard !line.hasPrefix("#") && !line.hasPrefix(";") && !line.hasPrefix("[") else { continue }
			guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
			let key = line[..<separator].trimmingCharacters(in: .whitespaces)
			let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
			guard !key.isEmpty && !value.isEmpty else { continue }
			if let int = Int(value) {
				candidates.append(_Candidate(keyPath: key, keyLower: key.lowercased(), intValue: int))
			} else if let double = Double(value) {
				candidates.append(_Candidate(keyPath: key, keyLower: key.lowercased(), doubleValue: double))
			} else {
				candidates.append(_Candidate(keyPath: key, keyLower: key.lowercased(), stringValue: value))
			}
		}
		return candidates
	}

	private static func _gates(
		from candidates: [_Candidate],
		fileText: String?,
		relativePath: String
	) -> [GraphicsGate] {
		// Highest numeric quality in this file: the patch raises a
		// capped quality towards it, never past 5 (Unity's
		// Fantastic level).
		let siblingMaxQuality = candidates
			.filter { _isQualityKey($0.keyLower) }
			.compactMap { $0.intValue }
			.max()

		let mentionsUltra = (fileText ?? "").lowercased().contains("ultra")
			|| candidates.compactMap({ $0.stringValue }).joined(separator: " ").lowercased().contains("ultra")

		var gates: [GraphicsGate] = []
		for candidate in candidates {
			if _isDeviceGateKey(candidate.keyLower),
			   let string = candidate.stringValue,
			   _looksLikeDeviceRestriction(key: candidate.keyLower, value: string) {
				gates.append(GraphicsGate(
					relativePath: relativePath,
					keyPath: candidate.keyPath,
					kind: .deviceGate,
					currentValue: string,
					patchedValue: ""
				))
			} else if _isFrameRateKey(candidate.keyLower) {
				if let int = candidate.intValue, int < 60 {
					gates.append(GraphicsGate(
						relativePath: relativePath,
						keyPath: candidate.keyPath,
						kind: .frameRateCap,
						currentValue: "\(int)",
						patchedValue: "60"
					))
				} else if let string = candidate.stringValue,
						  let leading = Int(string.prefix(while: { $0.isNumber })),
						  leading < 60 {
					gates.append(GraphicsGate(
						relativePath: relativePath,
						keyPath: candidate.keyPath,
						kind: .frameRateCap,
						currentValue: string,
						patchedValue: "60"
					))
				}
			} else if _isQualityKey(candidate.keyLower) {
				if let int = candidate.intValue, int < 5 {
					let target = min(5, max(siblingMaxQuality ?? int, int + 1))
					guard target > int else { continue }
					gates.append(GraphicsGate(
						relativePath: relativePath,
						keyPath: candidate.keyPath,
						kind: .qualityCap,
						currentValue: "\(int)",
						patchedValue: "\(target)"
					))
				} else if let double = candidate.doubleValue, double < 1.0 {
					gates.append(GraphicsGate(
						relativePath: relativePath,
						keyPath: candidate.keyPath,
						kind: .qualityCap,
						currentValue: "\(double)",
						patchedValue: "1.0"
					))
				} else if let string = candidate.stringValue {
					let lower = string.lowercased()
					let alreadyHigh = ["high", "ultra", "epic", "fantastic", "very high", "veryhigh", "highest"]
						.contains(lower)
					if ["low", "medium", "low quality", "medium quality"].contains(lower) && !alreadyHigh {
						gates.append(GraphicsGate(
							relativePath: relativePath,
							keyPath: candidate.keyPath,
							kind: .qualityCap,
							currentValue: string,
							patchedValue: mentionsUltra ? "Ultra" : "High"
						))
					}
				}
			}
		}
		return gates
	}

	private static func _isQualityKey(_ key: String) -> Bool {
		key.contains("quality") || key.contains("graphics")
			|| key == "msaa" || key.contains("antialiasing")
	}

	private static func _isFrameRateKey(_ key: String) -> Bool {
		key.contains("framerate") || key.contains("frame rate")
			|| key.contains("maxfps") || key.contains("fpslimit")
			|| key.contains("targetfps") || key == "fps"
	}

	private static func _isDeviceGateKey(_ key: String) -> Bool {
		key.contains("device") || key.contains("supporteddevice")
	}

	/// A device gate is a device/model restriction: a value that
	/// names iPhone/iPad models, or any value under a model /
	/// supported / allowed / whitelist key.
	private static func _looksLikeDeviceRestriction(key: String, value: String) -> Bool {
		let lower = value.lowercased()
		if lower.contains("iphone") || lower.contains("ipad") || lower.contains("ipod") {
			return lower.contains(where: { $0.isNumber })
		}
		return key.contains("model") || key.contains("supported")
			|| key.contains("allowed") || key.contains("whitelist")
	}

	// MARK: - Producing patched text

	private static func _patchedPlistText(data: Data, gates: [GraphicsGate]) -> String? {
		guard let top = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
			  var dict = top as? [String: Any] else {
			return nil
		}
		for gate in gates {
			let path = gate.keyPath.split(separator: ".").map(String.init)
			guard _mutateDict(&dict, path: path, gate: gate) else { return nil }
		}
		guard let out = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
			  let text = String(data: out, encoding: .utf8) else {
			return nil
		}
		return text
	}

	private static func _patchedJSONText(data: Data, gates: [GraphicsGate]) -> String? {
		guard let top = try? JSONSerialization.jsonObject(with: data),
			  var dict = top as? [String: Any] else {
			return nil
		}
		for gate in gates {
			let path = gate.keyPath.split(separator: ".").map(String.init)
			guard _mutateDict(&dict, path: path, gate: gate) else { return nil }
		}
		guard let out = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
			  let text = String(data: out, encoding: .utf8) else {
			return nil
		}
		return text
	}

	/// Sets (or, for a device gate, removes) the value at a dotted
	/// key path. Returns false when the path does not resolve to a
	/// dictionary key — the patch is then refused, not guessed.
	private static func _mutateDict(_ dict: inout [String: Any], path: [String], gate: GraphicsGate) -> Bool {
		guard let first = path.first else { return false }
		if path.count == 1 {
			guard let existing = dict[first] else { return false }
			if gate.kind == .deviceGate {
				dict.removeValue(forKey: first)
			} else if existing is String {
				// Keep the original type: a string cap stays a
				// string ("30" -> "60"), a number stays a number.
				dict[first] = gate.patchedValue
			} else if existing is NSNumber {
				if let int = Int(gate.patchedValue) {
					dict[first] = int
				} else if let double = Double(gate.patchedValue) {
					dict[first] = double
				} else {
					dict[first] = gate.patchedValue
				}
			} else {
				dict[first] = gate.patchedValue
			}
			return true
		}
		guard var nested = dict[first] as? [String: Any] else { return false }
		guard _mutateDict(&nested, path: Array(path.dropFirst()), gate: gate) else { return false }
		dict[first] = nested
		return true
	}

	private static func _patchedPlainText(text: String, gates: [GraphicsGate]) -> String? {
		var lines = text.components(separatedBy: "\n")
		for gate in gates {
			// For ini-style files the key path is the raw key; for
			// dotted paths only the last component is the key.
			let wantedKey = gate.keyPath.split(separator: ".").last.map(String.init)?.lowercased()
				?? gate.keyPath.lowercased()
			guard let index = lines.firstIndex(where: { _lineKey($0)?.lowercased() == wantedKey }) else {
				return nil
			}
			if gate.kind == .deviceGate {
				lines.remove(at: index)
			} else {
				guard let separator = lines[index].firstIndex(where: { $0 == "=" || $0 == ":" }) else {
					return nil
				}
				let keyPart = lines[index][..<separator]
				lines[index] = "\(keyPart)\(lines[index][separator])\(gate.patchedValue)"
			}
		}
		return lines.joined(separator: "\n")
	}

	/// The key part of a `key=value` / `key: value` line, or nil.
	private static func _lineKey(_ line: String) -> String? {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), !trimmed.hasPrefix("[") else {
			return nil
		}
		guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return nil }
		let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
		return key.isEmpty ? nil : key
	}

	// MARK: - Helpers

	private static func _diskText(for relativePath: String, in appDirectory: URL) -> String? {
		guard let url = _resolvedURL(for: relativePath, in: appDirectory),
			  let data = try? Data(contentsOf: url) else {
			return nil
		}
		return String(data: data, encoding: .utf8)
	}

	/// Resolves a relative path inside the bundle, refusing
	/// anything that would escape it (`..`, absolute paths).
	/// Same rule as ModFileEditor.
	private static func _resolvedURL(for relativePath: String, in appDirectory: URL) -> URL? {
		guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
		let components = relativePath.split(separator: "/").map(String.init)
		guard !components.contains(".."), !components.contains(".") else { return nil }
		let url = components.reduce(appDirectory) { $0.appendingPathComponent($1) }
		guard url.path.hasPrefix(appDirectory.path + "/") else { return nil }
		return url
	}
}
