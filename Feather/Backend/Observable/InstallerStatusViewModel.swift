//
//  StatusViewModel.swift
//  Zenith
//
//  Created by samara on 24.04.2025.
//

import Foundation
import Combine
import IDeviceSwift

extension InstallerStatusViewModel {
	var statusImage: String {
		switch status {
		case .none: "archivebox.fill"
		case .ready: "app.gift"
		case .sendingManifest, .sendingPayload: "paperplane.fill"
		case .installing: "square.and.arrow.down"
		case .completed: "app.badge.checkmark"
		case .broken: "exclamationmark.triangle.fill"
		}
	}
	
	var statusLabel: String {
		switch status {
		case .none: .localized("Packaging")
		case .ready: .localized("Ready")
		case .sendingManifest: .localized("Sending Manifest")
		case .sendingPayload: .localized("Sending Payload")
		case .installing: .localized("Installing")
		case .completed: .localized("Completed")
		case .broken: .localized("Error")
		}
	}

	// Zenith v2.24: the real failure behind a .broken status.
	// The sheet used to show only statusLabel ("خطأ") and drop
	// the attached error, so an install that installd rejected
	// ended on a bare warning triangle with no diagnosis. The
	// install-failure errors already carry Iraqi-dialect
	// descriptions (InstallLinkError); a system error shows its
	// own description. Shown under the status line so the next
	// test gives a diagnosis instead of a bare triangle.
	var statusDetail: String? {
		if case .broken(let error) = status {
			return error.localizedDescription
		}
		return nil
	}
}
