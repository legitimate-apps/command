//
//  Keychain.swift
//  Command
//
//  Thin wrapper over the iOS Keychain for the device-lock + multi-user features. Every item
//  is stored `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: encrypted at rest, available only
//  while the device is unlocked, bound to THIS device, never synced to iCloud and excluded from
//  backups. That hardware protection — plus the lockout policy — is what makes a low-entropy
//  PIN safe; the stored verifier alone would be trivially brute-forced.
//

import Foundation
import Security

enum Keychain {
    /// Upsert `data` under (service, account). Returns false on an OSStatus error.
    @discardableResult
    static func set(_ data: Data, service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // replace any existing item
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: Codable convenience

    static func setCodable<T: Encodable>(_ value: T, service: String, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return set(data, service: service, account: account)
    }

    static func getCodable<T: Decodable>(_ type: T.Type, service: String, account: String) -> T? {
        guard let data = get(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
