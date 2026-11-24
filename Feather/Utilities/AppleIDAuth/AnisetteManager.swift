//
//  AnisetteManager.swift
//  Feather
//
//  On-device Anisette data (Apple device identity) for Apple ID sign-in.
//  Built on SideSign's AnisetteDataManager (GPLv3) over AnisetteKit (AGPLv3).
//
//  How it works: Apple requires an "anisette" attestation with every Apple ID
//  sign-in. The attestation is derived from a device identity blob (adi.pb)
//  that is provisioned once per device and reused afterwards. The blob is
//  stored in the Keychain and never leaves the device.
//
//  Defaults are SideStore's public ones and can be changed by the user:
//  the anisette servers list and the on-device-anisette (ODA) package
//  metadata. No server of ours is involved and nothing is paid.
//
//  Honest limits (see FEATHER_MOD_PLAN.md §5):
//  - The ODA package download and the Apple handshake are only exercised on
//    a real device; this code has never run against Apple from here.
//  - If Apple changes the protocol, sign-in fails with a clear error —
//    nothing is faked.

import Foundation
import SideSign

actor AnisetteManager {
	static let shared = AnisetteManager()
	
	// MARK: - Defaults (public community resources, user-changeable)
	
	/// List of anisette servers (SideStore's public default).
	static let defaultServersURLString = "https://servers.sidestore.io/servers.json"
	/// On-device-anisette package metadata (SideStore's public default).
	static let defaultODAURLString = "https://zzz.haus/oda.json"
	
	private static let _serversURLKey = "Feather.anisetteServersURL"
	private static let _odaURLKey = "Feather.anisetteODAURL"
	private static let _deviceIDKey = "Feather.anisetteDeviceID"
	private static let _keychainService = "feather.anisette"
	private static let _keychainAccount = "adiPb"
	
	private init() {}
	
	// MARK: - Configuration
	
	var serversURL: URL {
		let raw = UserDefaults.standard.string(forKey: Self._serversURLKey)
			?? Self.defaultServersURLString
		return URL(string: raw) ?? URL(string: Self.defaultServersURLString)!
	}
	
	var odaURL: URL {
		let raw = UserDefaults.standard.string(forKey: Self._odaURLKey)
			?? Self.defaultODAURLString
		return URL(string: raw) ?? URL(string: Self.defaultODAURLString)!
	}
	
	/// A stable per-device identifier used for anisette provisioning.
	/// Created once and kept in UserDefaults; it is not the UDID.
	var deviceIdentifier: UUID {
		if let raw = UserDefaults.standard.string(forKey: Self._deviceIDKey),
		   let uuid = UUID(uuidString: raw) {
			return uuid
		}
		
		let uuid = UUID()
		UserDefaults.standard.set(uuid.uuidString, forKey: Self._deviceIDKey)
		return uuid
	}
	
	private var _baseDirectory: URL {
		let support = FileManager.default.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask
		).first ?? FileManager.default.temporaryDirectory
		return support.appendingPathComponent("Feather/Anisette", isDirectory: true)
	}
	
	private var _existingAdiBlob: Data? {
		KeychainHelper.load(service: Self._keychainService, account: Self._keychainAccount)
	}
	
	private func _saveAdiBlob(_ blob: Data) {
		KeychainHelper.save(blob, service: Self._keychainService, account: Self._keychainAccount)
	}
	
	// MARK: - Fetch
	
	/// Returns fresh anisette data for one Apple ID sign-in.
	/// Reuses the provisioned adi.pb from the Keychain when present; when
	/// Apple provisions a new blob, it is saved back to the Keychain.
	func fetchAnisetteData() async throws -> AnisetteData {
		let manager = AnisetteDataManager(
			mode: .remoteODA(sourceURL: serversURL, fallbackURL: odaURL),
			baseDirectory: _baseDirectory
		)
		
		let (data, newBlob) = try await manager.fetchAnisetteData(
			identifier: deviceIdentifier,
			existingAdiBlob: _existingAdiBlob
		)
		
		if let newBlob {
			_saveAdiBlob(newBlob)
		}
		
		return data
	}
	
	/// Forget the provisioned identity (forces a fresh provisioning next time).
	func resetIdentity() {
		KeychainHelper.delete(service: Self._keychainService, account: Self._keychainAccount)
		UserDefaults.standard.removeObject(forKey: Self._deviceIDKey)
	}
}
