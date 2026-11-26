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
	/// True when this cell is nested inside another cell's disclosure
	/// group: it gets a faintly lighter fill so the inner card reads
	/// as a separate surface from its parent card (v2.10, no lines).
	let isNested: Bool
	@State private var _isExpanded = false

	// v2.10 fix: explicit init — the synthesized memberwise init does not
	// expose `isNested` (it only takes key/value). Note: the property has
	// NO default value here — a `let` with `= false` is already initialized
	// by its default, so assigning it in init fails with "may only be
	// initialized once"; the default lives on the parameter instead.
	init(key: String, value: Any, isNested: Bool = false) {
		self.key = key
		self.value = value
		self.isNested = isNested
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
		.overlay {
			if isNested {
				RoundedRectangle(cornerRadius: 12, style: .continuous)
					.fill(Color.white.opacity(0.04))
			}
		}
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
	}
	
	private func _makeDisclosureGroup(items: [(String, Any)]) -> some View {
		DisclosureGroup(isExpanded: $_isExpanded) {
			ForEach(items, id: \.0) { item in
				CertificatesInfoEntitlementCellView(key: item.0, value: item.1, isNested: true)
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
