//
//  KeychainHelper.swift
//  Zenith
//
//  Small Keychain wrapper for the Apple ID flow: the Anisette identity blob
//  (adi.pb) and the Apple ID session. No passwords are ever stored here —
//  only opaque session/blob data. Everything stays on-device, free only.
//

import Foundation
import Security

enum KeychainHelper {
	@discardableResult
	static func save(_ data: Data, service: String, account: String) -> Bool {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account
		]
		
		SecItemDelete(query as CFDictionary)
		
		var attributes = query
		attributes[kSecValueData as String] = data
		// Local only: this identity must never sync to iCloud.
		attributes[kSecAttrSynchronizable as String] = false
		
		return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
	}
	
	static func load(service: String, account: String) -> Data? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne
		]
		
		var result: AnyObject?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
			return nil
		}
		
		return result as? Data
	}
	
	@discardableResult
	static func delete(service: String, account: String) -> Bool {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account
		]
		
		return SecItemDelete(query as CFDictionary) == errSecSuccess
	}
}
