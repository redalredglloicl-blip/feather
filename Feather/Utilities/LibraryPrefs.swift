
//
//  LibraryPrefs.swift
//  Zenith
//
//  Zenith — per-app Library preferences stored locally in UserDefaults,
//  keyed by app UUID. No Core Data model change, so existing Library data
//  is never touched.
//

import Foundation
import Combine

// MARK: - Value Editor Games (Zenith v2.38 Part B)

/// One game the Value Editor was injected into WITHOUT signing
/// (Library long-press menu, "إضافة محرر القيم للعبة"). The
/// modified IPA itself lives in Documents/Archives; this record
/// is only the pointer the Home section "الألعاب المضاف لها
/// محرر القيم" lists, so the list survives relaunch. Keyed by
/// the Library app UUID; re-injecting the same game overwrites
/// its record with the newest IPA.
struct ValueEditorGame: Codable, Equatable {
	var uuid: String
	var name: String
	var version: String?
	var ipaPath: String
	var date: TimeInterval
}

// MARK: - Class
final class LibraryPrefs: ObservableObject {
	static let shared = LibraryPrefs()

	/// Apps not opened for this long are suggested for deletion.
	static let unusedThreshold: TimeInterval = 30 * 24 * 60 * 60

	private enum Keys {
		static let favorites = "Zenith.favorites"
		static let categories = "Zenith.categories"
		static let lastOpened = "Zenith.lastOpened"
		static let showExpired = "Zenith.showExpired"
		static let valueEditorGames = "Zenith.valueEditorGames"
	}
	
	@Published var favorites: Set<String> = [] {
		didSet { UserDefaults.standard.set(Array(favorites), forKey: Keys.favorites) }
	}
	
	@Published var categories: [String: String] = [:] {
		didSet {
			if let data = try? JSONEncoder().encode(categories) {
				UserDefaults.standard.set(data, forKey: Keys.categories)
			}
		}
	}
	
	@Published var lastOpened: [String: TimeInterval] = [:] {
		didSet {
			if let data = try? JSONEncoder().encode(lastOpened) {
				UserDefaults.standard.set(data, forKey: Keys.lastOpened)
			}
		}
	}
	
	@Published var showExpired: Bool = false {
		didSet { UserDefaults.standard.set(showExpired, forKey: Keys.showExpired) }
	}

	/// Zenith v2.38 Part B: games with the Value Editor injected
	/// (unsigned IPA in Documents/Archives), keyed by Library
	/// app UUID. Persists in UserDefaults, like favorites.
	@Published var valueEditorGames: [String: ValueEditorGame] = [:] {
		didSet {
			if let data = try? JSONEncoder().encode(valueEditorGames) {
				UserDefaults.standard.set(data, forKey: Keys.valueEditorGames)
			}
		}
	}

	private init() {
		favorites = Set(UserDefaults.standard.stringArray(forKey: Keys.favorites) ?? [])

		if let data = UserDefaults.standard.data(forKey: Keys.categories),
		   let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
			categories = decoded
		}

		if let data = UserDefaults.standard.data(forKey: Keys.lastOpened),
		   let decoded = try? JSONDecoder().decode([String: TimeInterval].self, from: data) {
			lastOpened = decoded
		}

		if let data = UserDefaults.standard.data(forKey: Keys.valueEditorGames),
		   let decoded = try? JSONDecoder().decode([String: ValueEditorGame].self, from: data) {
			valueEditorGames = decoded
		}

		showExpired = UserDefaults.standard.bool(forKey: Keys.showExpired)
	}
}

// MARK: - Extension: Favorites
extension LibraryPrefs {
	func isFavorite(uuid: String?) -> Bool {
		guard let uuid else { return false }
		return favorites.contains(uuid)
	}
	
	func toggleFavorite(uuid: String?) {
		guard let uuid else { return }
		if favorites.contains(uuid) {
			favorites.remove(uuid)
		} else {
			favorites.insert(uuid)
		}
	}
}

// MARK: - Extension: Categories
extension LibraryPrefs {
	func category(for uuid: String?) -> LibraryView.HomeCategory {
		guard
			let uuid,
			let raw = categories[uuid],
			let category = LibraryView.HomeCategory(rawValue: raw)
		else {
			return .all
		}
		return category
	}
	
	func setCategory(_ category: LibraryView.HomeCategory, for uuid: String?) {
		guard let uuid else { return }
		if category == .all {
			categories.removeValue(forKey: uuid)
		} else {
			categories[uuid] = category.rawValue
		}
	}
}

// MARK: - Extension: Last Opened
extension LibraryPrefs {
	func lastOpenedDate(for uuid: String?) -> Date? {
		guard let uuid, let interval = lastOpened[uuid] else { return nil }
		return Date(timeIntervalSince1970: interval)
	}
	
	func recordOpened(uuid: String?) {
		guard let uuid else { return }
		lastOpened[uuid] = Date().timeIntervalSince1970
	}
}

// MARK: - Extension: Expiry
extension LibraryPrefs {
	/// A signed app whose certificate has expired. Imported (unsigned) apps never expire.
	func isExpired(app: AppInfoPresentable) -> Bool {
		guard app.isSigned else { return false }
		guard let expiration = Storage.shared.getCertificate(from: app)?.expiration else { return false }
		return expiration <= Date()
	}
}

// MARK: - Extension: Value Editor Games (Zenith v2.38 Part B)
extension LibraryPrefs {
	/// Records a game whose unsigned Value Editor IPA was just
	/// built. Re-injecting the same game overwrites its record
	/// with the newest IPA.
	func recordValueEditorGame(uuid: String, name: String, version: String?, ipaURL: URL) {
		valueEditorGames[uuid] = ValueEditorGame(
			uuid: uuid,
			name: name,
			version: version,
			ipaPath: ipaURL.path,
			date: Date().timeIntervalSince1970
		)
	}

	/// Injected games, newest first, for the Home section.
	func valueEditorGameList() -> [ValueEditorGame] {
		valueEditorGames.values.sorted { $0.date > $1.date }
	}

	/// The modified IPA file for a game, or nil when the record
	/// is missing or the file itself is gone (deleted from
	/// Files, for example) — the section then says so instead
	/// of opening a share sheet for a missing file.
	func valueEditorGameIPAURL(for uuid: String) -> URL? {
		guard let game = valueEditorGames[uuid] else { return nil }
		let url = URL(fileURLWithPath: game.ipaPath)
		guard FileManager.default.fileExists(atPath: url.path) else { return nil }
		return url
	}

	/// Zenith v2.40: removes the game's record AND deletes its
	/// modified IPA file from Documents/Archives. The file
	/// delete is best-effort — when the file is already gone,
	/// the record is still removed and nothing errors.
	/// Removing the dictionary entry fires the @Published
	/// didSet, so the change persists and the Home section
	/// refreshes at once.
	func removeValueEditorGame(uuid: String) {
		guard let game = valueEditorGames[uuid] else { return }
		valueEditorGames.removeValue(forKey: uuid)
		let ipaURL = URL(fileURLWithPath: game.ipaPath)
		try? FileManager.default.removeItem(at: ipaURL)
	}
}
