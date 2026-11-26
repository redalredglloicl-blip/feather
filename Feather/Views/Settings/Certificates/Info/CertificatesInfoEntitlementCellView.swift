//
//  CertificatesInfoEntitlementCellView.swift
//  Zenith
//
//  Created by samara on 27.04.2025.
//

import SwiftUI

// MARK: - View
struct CertificatesInfoEntitlementCellView: View {
	let key: String
	let value: Any
	@State private var _isExpanded = false

	// Explicit init (kept from v2.10; the synthesized memberwise init
	// is equivalent now that `isNested` is gone in v2.11).
	init(key: String, value: Any) {
		self.key = key
		self.value = value
	}
	
	// MARK: Body
	var body: some View {
		Group {
			if let dict = value as? [String: Any] {
				_makeDisclosureGroup(items: dict.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 })
			} else if let array = value as? [Any] {
				_makeDisclosureGroup(items: array.enumerated().map { ("\($0)", $1) })
			} else {
				HStack {
					Text(key)
					Spacer()
					Text(_formatted(value))
						.foregroundStyle(.secondary)
						.copyableText(_formatted(value))
				}
			}
		}
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
	}
	
	private func _makeDisclosureGroup(items: [(String, Any)]) -> some View {
		DisclosureGroup(isExpanded: $_isExpanded) {
			ForEach(items, id: \.0) { item in
				CertificatesInfoEntitlementCellView(key: item.0, value: item.1)
			}
		} label: {
			Text(key)
		}
	}
	
	private func _formatted(_ value: Any) -> String {
		switch value {
		case let bool as Bool: return bool ? "✓" : "✗"
		case let number as NSNumber: return number.stringValue
		case let string as String: return string
		default: return String(describing: value)
		}
	}
}
