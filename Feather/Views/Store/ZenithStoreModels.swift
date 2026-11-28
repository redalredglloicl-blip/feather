//
//  ZenithStoreModels.swift
//  Zenith
//
//  Zenith 2.37 (Store): data models for the Zenith Store tab.
//
//  The store lists REAL apps and games from 12 live AltStore-source
//  JSON feeds (AltStore official, OatmealDome, Provenance, Emily's
//  Apps, UTM official, PokeMMO, iSH, CyPwn IPA Library, SideStore
//  Community, Quantum Source, WuXu's Library++, Quantum++). Nothing
//  here is faked: every entry comes from one of those feeds, with
//  a real download link.
//
//  AltSource feeds come in two shapes, and both must decode:
//  * v1 (flat): version / versionDate / downloadURL / size live on
//    the app object itself (CyPwn, SideStore).
//  * v2 (versions array): the app object carries NO version,
//    downloadURL or size — those live in versions[] entries, newest
//    first (Quantum). versions[0] is the latest version.
//  A v1 app may ALSO carry a versions[] array (SideStore does);
//  when present, versions[0] wins over the flat fields.

import Foundation

// MARK: - One version of a store app

struct ZenithStoreAppVersion: Codable, Identifiable, Equatable {
	var id: String { version }
	var version: String
	var date: String?
	var downloadURL: URL?
	var size: Int64?

	var dateParsed: Date? {
		guard let date else { return nil }
		return ZenithStoreAppVersion._parseDate(date)
	}

	// Feeds disagree on the date format: "2026-07-23" (date only),
	// "2024-03-01T03:47:43Z" (ISO8601),
	// "2025-02-22T21:37:29-05:00" (ISO8601 with offset) and
	// "2026-11-28T09:31:19.767Z" (ISO8601 with fractional
	// seconds — Provenance iCube, OatmealDome DolphiniOS).
	static func _parseDate(_ text: String) -> Date? {
		let iso = ISO8601DateFormatter()
		// Fractional seconds first: the plain internet-time
		// format rejects them, so without this attempt those
		// feeds' dates would never parse.
		iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		if let date = iso.date(from: text) { return date }
		iso.formatOptions = [.withInternetDateTime]
		if let date = iso.date(from: text) { return date }
		iso.formatOptions = [.withFullDate]
		if let date = iso.date(from: text) { return date }
		let plain = DateFormatter()
		plain.locale = Locale(identifier: "en_US_POSIX")
		plain.dateFormat = "yyyy-MM-dd"
		return plain.date(from: text)
	}

	enum CodingKeys: String, CodingKey {
		case version
		case date
		case downloadURL
		case size
	}

	init(version: String, date: String? = nil, downloadURL: URL? = nil, size: Int64? = nil) {
		self.version = version
		self.date = date
		self.downloadURL = downloadURL
		self.size = size
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
		date = try container.decodeIfPresent(String.self, forKey: .date)
		if let urlString = try container.decodeIfPresent(String.self, forKey: .downloadURL) {
			downloadURL = URL(string: urlString)
		}
		size = try container.decodeIfPresent(Int64.self, forKey: .size)
	}
}

// MARK: - Version comparison

enum ZenithStoreVersion {
	// True when `candidate` is newer than `installed`. Compares
	// numeric dot segments ("1.10" beats "1.9"); a trailing
	// non-numeric suffix only breaks ties, so "1.2.3b" counts as
	// newer than "1.2.3", and "1.2" equals "1.2.0". Anything
	// unparseable is never treated as newer.
	static func isNewer(_ candidate: String, than installed: String) -> Bool {
		let left = _segments(candidate)
		let right = _segments(installed)
		guard !left.isEmpty, !right.isEmpty else { return false }
		let count = max(left.count, right.count)
		for index in 0..<count {
			let l = index < left.count ? left[index] : (0, "")
			let r = index < right.count ? right[index] : (0, "")
			if l.0 != r.0 { return l.0 > r.0 }
			if l.1 != r.1 {
				// Same number, different suffix: a suffix beats
				// no suffix ("1.2.3b" > "1.2.3"); two suffixes
				// compare alphabetically ("1.2b" > "1.2a").
				if l.1.isEmpty { return false }
				if r.1.isEmpty { return true }
				return l.1 > r.1
			}
		}
		return false
	}

	// One dot segment split into its leading number and any
	// trailing suffix ("3b" -> (3, "b"), "10" -> (10, "")).
	private static func _segments(_ version: String) -> [(Int, String)] {
		version.split(separator: ".").map { part in
			let text = String(part)
			let digits = text.prefix(while: { $0.isNumber })
			let number = Int(digits) ?? 0
			let suffix = String(text.dropFirst(digits.count))
			return (number, suffix)
		}
	}
}

// MARK: - Normalized store app

struct ZenithStoreApp: Codable, Identifiable, Equatable {
	var id: String { bundleIdentifier }

	var name: String
	var bundleIdentifier: String
	var developerName: String?
	var version: String
	var versionDate: String?
	var downloadURL: URL?
	var size: Int64?
	var iconURL: URL?
	var screenshotURLs: [URL]
	var localizedDescription: String?
	var subtitle: String?
	var sourceName: String
	var versionHistory: [ZenithStoreAppVersion]

	var versionDateParsed: Date? {
		guard let versionDate else { return nil }
		return ZenithStoreAppVersion._parseDate(versionDate)
	}

	// Game or app? AltSource carries NO category field, so this is
	// a keyword heuristic over the name, subtitle and description:
	// known emulator / game names, plus the words "emulator",
	// "game" and "لعبة". Everything else counts as an app. A
	// borderline entry may land on the wrong side — the search
	// still finds it either way.
	var isGame: Bool {
		let haystack = [name, subtitle, localizedDescription]
			.compactMap { $0 }
			.joined(separator: " ")
			.lowercased()
		for keyword in Self._gameKeywords where haystack.contains(keyword) {
			return true
		}
		return false
	}

	private static let _gameKeywords: [String] = [
		"ppsspp", "retroarch", "delta", "dolphin", "provenance",
		"mame", "gba", "nds", "inds", "play!", "scummvm",
		"flycast", "citra", "emuthreeds", "deltroid", "vcmi",
		"flappy", "terraria", "fortnite", "deltarune", "cloverpit",
		"powerwarriors", "true skate", "stiknes", "firebird",
		"activegs", "pokemmo", "mini vmac", "idos", "rewound",
		"emulator", "game", "لعبة", "لعبه", "محاكي"
	]

	enum CodingKeys: String, CodingKey {
		case name
		case bundleIdentifier
		case developerName
		case version
		case versionDate
		case downloadURL
		case size
		case iconURL
		case screenshotURLs
		case localizedDescription
		case subtitle
		case sourceName
		case versions
	}

	init(
		name: String,
		bundleIdentifier: String,
		developerName: String? = nil,
		version: String = "",
		versionDate: String? = nil,
		downloadURL: URL? = nil,
		size: Int64? = nil,
		iconURL: URL? = nil,
		screenshotURLs: [URL] = [],
		localizedDescription: String? = nil,
		subtitle: String? = nil,
		sourceName: String = "",
		versionHistory: [ZenithStoreAppVersion] = []
	) {
		self.name = name
		self.bundleIdentifier = bundleIdentifier
		self.developerName = developerName
		self.version = version
		self.versionDate = versionDate
		self.downloadURL = downloadURL
		self.size = size
		self.iconURL = iconURL
		self.screenshotURLs = screenshotURLs
		self.localizedDescription = localizedDescription
		self.subtitle = subtitle
		self.sourceName = sourceName
		self.versionHistory = versionHistory
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		guard let bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
			  !bundleIdentifier.isEmpty else {
			throw DecodingError.dataCorruptedError(
				forKey: .bundleIdentifier,
				in: container,
				debugDescription: "Store app without a bundleIdentifier"
			)
		}
		self.bundleIdentifier = bundleIdentifier
		name = try container.decodeIfPresent(String.self, forKey: .name) ?? bundleIdentifier
		developerName = try container.decodeIfPresent(String.self, forKey: .developerName)
		subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
		localizedDescription = try container.decodeIfPresent(String.self, forKey: .localizedDescription)
		sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? ""

		if let iconString = try container.decodeIfPresent(String.self, forKey: .iconURL) {
			iconURL = URL(string: iconString)
		}
		let screenshotStrings = try container.decodeIfPresent([String].self, forKey: .screenshotURLs) ?? []
		screenshotURLs = screenshotStrings.compactMap { URL(string: $0) }

		// v2: versions[] carries the real version info. v1: the
		// flat fields do. versions[0] wins when both exist.
		let versions = try container.decodeIfPresent([ZenithStoreAppVersion].self, forKey: .versions) ?? []
		versionHistory = versions
		// Flat v1 fields, decoded once — `??` and `?:` cannot carry
		// their own `try` (the operator itself would need it).
		let flatVersion = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
		let flatVersionDate = try container.decodeIfPresent(String.self, forKey: .versionDate)
		let flatSize = try container.decodeIfPresent(Int64.self, forKey: .size)
		if let latest = versions.first {
			version = latest.version.isEmpty ? flatVersion : latest.version
			versionDate = latest.date ?? flatVersionDate
			downloadURL = latest.downloadURL
				?? Self._url(from: container, key: .downloadURL)
			size = latest.size ?? flatSize
		} else {
			version = flatVersion
			versionDate = flatVersionDate
			downloadURL = Self._url(from: container, key: .downloadURL)
			size = flatSize
			// Keep a one-entry history so the detail screen can
			// always show the current version the same way.
			if !version.isEmpty {
				versionHistory = [
					ZenithStoreAppVersion(
						version: version,
						date: versionDate,
						downloadURL: downloadURL,
						size: size
					)
				]
			}
		}
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(name, forKey: .name)
		try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
		try container.encodeIfPresent(developerName, forKey: .developerName)
		try container.encode(version, forKey: .version)
		try container.encodeIfPresent(versionDate, forKey: .versionDate)
		try container.encodeIfPresent(downloadURL?.absoluteString, forKey: .downloadURL)
		try container.encodeIfPresent(size, forKey: .size)
		try container.encodeIfPresent(iconURL?.absoluteString, forKey: .iconURL)
		try container.encode(screenshotURLs.map { $0.absoluteString }, forKey: .screenshotURLs)
		try container.encodeIfPresent(localizedDescription, forKey: .localizedDescription)
		try container.encodeIfPresent(subtitle, forKey: .subtitle)
		try container.encode(sourceName, forKey: .sourceName)
		try container.encode(versionHistory, forKey: .versions)
	}

	// A downloadURL stored as a plain string in JSON; URL(string:)
	// fails on odd characters instead of throwing, so decode it
	// lossily here rather than through the URL decoder.
	private static func _url(
		from container: KeyedDecodingContainer<CodingKeys>,
		key: CodingKeys
	) -> URL? {
		guard let text = try? container.decodeIfPresent(String.self, forKey: key) else {
			return nil
		}
		return URL(string: text)
	}
}

// MARK: - Feed envelope (tolerant: one bad app never kills the feed)

struct ZenithStoreFeed: Decodable {
	var apps: [ZenithStoreApp]

	enum CodingKeys: String, CodingKey {
		case apps
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		// Lossy array: one bad app decodes to nil and is dropped,
		// the rest of the feed still loads.
		apps = try container.decode([_LossyApp].self, forKey: .apps)
			.compactMap { $0.app }
	}

	// Wraps one app; a throw inside ZenithStoreApp's own init is
	// caught here, so the array decoder still consumes the element
	// normally and moves on to the next one.
	private struct _LossyApp: Decodable {
		let app: ZenithStoreApp?

		init(from decoder: Decoder) throws {
			app = try? ZenithStoreApp(from: decoder)
		}
	}
}
