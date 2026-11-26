//
//  ConfigurationDictAddView.swift
//  Zenith
//
//  Created by samara on 20.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct ConfigurationDictAddView: View {
	@Environment(\.dismiss) var dismiss
	
	@State private var _newKey = ""
	@State private var _newValue = ""
	@State private var _showOverrideAlert = false
	
	var saveButtonDisabled: Bool {
		_newKey.isEmpty || _newValue.isEmpty
	}
	
	@Binding var dataDict: [String: String]
	
	// MARK: Body
	var body: some View {
		NBList(.localized("New")) {
			Section {
				TextField(.localized("Value"), text: $_newKey)
					.zenithGlassCard(cornerRadius: 12)
					.listRowSeparator(.hidden)
					.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
				TextField(.localized("Replacement"), text: $_newValue)
					.zenithGlassCard(cornerRadius: 12)
					.listRowSeparator(.hidden)
					.listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
			}
			.autocapitalization(.none)
		}
		.starfieldBackground()
		.toolbar {
			NBToolbarButton(
				.localized("Save"),
				style: .text,
				placement: .confirmationAction,
				isDisabled: saveButtonDisabled
			) {
				dataDict[_newKey] = _newValue
				OptionsManager.shared.saveOptions()
				dismiss()
			}
		}
	}
}
