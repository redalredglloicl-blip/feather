//
//  CustomAppIconStore.swift
//  Feather
//
//  Zenith v2.2: a custom icon picked at sign time, kept per app and
//  used for the app's Library icon. Keyed by bundle identifier — the
//  identifier survives re-signs, while the signed record's UUID does
//  not. Files live in Documents/ZenithCustomIcons, local only, one
//  PNG per identifier. The signed bundle itself also carries the
//  icon (SigningHandler bakes it in); this store is what makes the
//  Library show it even when the bundle icon cannot be read.
//

import Foundation
import UIKit

// MARK: - Store
final class CustomAppIconStore {
	static let shared = CustomAppIconStore()

	private init() {}

	// MARK: Paths

	private var _directory: URL {
		URL.documentsDirectory.appendingPathComponent("ZenithCustomIcons", isDirectory: true)
	}

	private func _fileURL(for identifier: String?) -> URL? {
		guard let identifier, !identifier.isEmpty else {
			return nil
		}
		// Identifiers are reverse-DNS; keep only safe characters so
		// the name is always a valid single file name.
		let safe = identifier.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }
		return _directory.appendingPathComponent(String(safe)).appendingPathExtension("png")
	}

	// MARK: Read / Write

	/// The stored custom icon for this bundle identifier, if any.
	func image(for identifier: String?) -> UIImage? {
		guard
			let url = _fileURL(for: identifier),
			let image = UIImage(contentsOfFile: url.path)
		else {
			return nil
		}
		return image
	}

	/// True when a custom icon is stored for this identifier.
	func hasCustomIcon(for identifier: String?) -> Bool {
		guard let url = _fileURL(for: identifier) else {
			return false
		}
		return FileManager.default.fileExists(atPath: url.path)
	}

	/// Stores the picked icon (square, PNG) for this identifier.
	/// Overwrites any previous custom icon for the same app.
	func save(_ image: UIImage, for identifier: String?) {
		guard
			let url = _fileURL(for: identifier),
			let data = (image.resizeToSquare() ?? image).pngData()
		else {
			return
		}
		try? FileManager.default.createDirectory(at: _directory, withIntermediateDirectories: true)
		try? data.write(to: url, options: .atomic)
	}

	/// Removes the stored custom icon, e.g. when the app is deleted.
	func remove(for identifier: String?) {
		guard let url = _fileURL(for: identifier) else {
			return
		}
		try? FileManager.default.removeItem(at: url)
	}
}
