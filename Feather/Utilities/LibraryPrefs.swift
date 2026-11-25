
//
//  LibraryPrefs.swift
//  Feather
//
//  Zenith — per-app Library preferences stored locally in UserDefaults,
//  keyed by app UUID. No Core Data model change, so existing Library data
//  is never touched.
//

import Foundation
import Combine

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
