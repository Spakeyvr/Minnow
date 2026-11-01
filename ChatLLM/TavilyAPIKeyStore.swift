//
//  TavilyAPIKeyStore.swift
//  ChatLLM
//
//  Shared persistence for the optional Tavily API key.
//

import Foundation
import Security
import os.log

enum TavilyAPIKeyStore {
    static let userDefaultsKey = "tavilyApiKey"
    static let service = "\(Bundle.main.bundleIdentifier ?? "Nevio.ChatLLM").web-search"
    private static let legacyService = "com.yourapp.tavily"
    static let account = "TavilyAPIKey"
    static let didChangeNotification = Notification.Name("TavilyKeyChanged")

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ChatLLM",
        category: "TavilyAPIKeyStore"
    )

    private enum KeychainRead {
        case found(String)
        case notFound
        /// The Keychain could not answer, for example while the device is locked.
        case unavailable(OSStatus)
    }

    private struct CacheKey: Hashable {
        let service: String
        let account: String
    }

    /// Each view model and the settings screen ask for the key, and every
    /// Keychain read is a round trip to securityd on the main thread. Only
    /// definite answers are cached; save and clear keep the cache current.
    private static var cachedKeys: [CacheKey: String?] = [:]

    static func currentKey(
        userDefaults: UserDefaults = .standard,
        service: String = TavilyAPIKeyStore.service,
        account: String = TavilyAPIKeyStore.account
    ) -> String? {
        let cacheKey = CacheKey(service: service, account: account)
        // Cheap in-memory check; a plaintext key from an old build may appear
        // in any defaults suite.
        if userDefaults.object(forKey: userDefaultsKey) != nil {
            migrateLegacyPlaintextKeyIfNeeded(
                userDefaults: userDefaults,
                service: service,
                account: account
            )
        }
        if let cached = cachedKeys[cacheKey] {
            return cached
        }

        switch getKeychainValue(service: service, account: account) {
        case .found(let current):
            cachedKeys[cacheKey] = current
            return current
        case .unavailable:
            return nil
        case .notFound:
            break
        }

        guard service == Self.service else {
            cachedKeys[cacheKey] = .some(nil)
            return nil
        }
        switch getKeychainValue(service: legacyService, account: account) {
        case .found(let legacy):
            if saveKeychainValue(legacy, service: service, account: account) {
                deleteKeychainValue(service: legacyService, account: account)
                cachedKeys[cacheKey] = legacy
            }
            return legacy
        case .notFound:
            cachedKeys[cacheKey] = .some(nil)
            return nil
        case .unavailable:
            return nil
        }
    }

    /// Returns false when the Keychain rejected the key, so callers can tell
    /// the user it was not saved.
    @discardableResult
    static func save(
        _ key: String,
        userDefaults: UserDefaults = .standard,
        service: String = TavilyAPIKeyStore.service,
        account: String = TavilyAPIKeyStore.account
    ) -> Bool {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            clear(
                userDefaults: userDefaults,
                service: service,
                account: account
            )
            return true
        }

        guard saveKeychainValue(trimmedKey, service: service, account: account) else {
            cachedKeys.removeValue(forKey: CacheKey(service: service, account: account))
            return false
        }
        cachedKeys[CacheKey(service: service, account: account)] = trimmedKey
        userDefaults.removeObject(forKey: userDefaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return true
    }

    static func clear(
        userDefaults: UserDefaults = .standard,
        service: String = TavilyAPIKeyStore.service,
        account: String = TavilyAPIKeyStore.account,
        postNotification: Bool = true
    ) {
        deleteKeychainValue(service: service, account: account)
        if service == Self.service {
            deleteKeychainValue(service: legacyService, account: account)
        }
        userDefaults.removeObject(forKey: userDefaultsKey)
        cachedKeys[CacheKey(service: service, account: account)] = .some(nil)

        if postNotification {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    private static func migrateLegacyPlaintextKeyIfNeeded(
        userDefaults: UserDefaults,
        service: String,
        account: String
    ) {
        guard userDefaults.object(forKey: userDefaultsKey) != nil else {
            return
        }

        let legacyValue = userDefaults.string(forKey: userDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !legacyValue.isEmpty else {
            userDefaults.removeObject(forKey: userDefaultsKey)
            return
        }

        let isStored: Bool
        if case .found(legacyValue) = getKeychainValue(service: service, account: account) {
            isStored = true
        } else {
            isStored = saveKeychainValue(legacyValue, service: service, account: account)
        }

        // Keep the only copy of the key until the Keychain holds it, for
        // example when a locked device rejects the write; the next read retries.
        guard isStored else {
            logger.error("Tavily key migration deferred: Keychain write failed")
            return
        }
        cachedKeys[CacheKey(service: service, account: account)] = legacyValue
        userDefaults.removeObject(forKey: userDefaultsKey)
    }

    @discardableResult
    private static func saveKeychainValue(_ value: String, service: String, account: String) -> Bool {
        guard let valueData = value.data(using: .utf8) else {
            logger.error("Tavily key save failed: UTF-8 encoding returned nil")
            return false
        }

        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            logger.error("Tavily key SecItemUpdate failed: OSStatus \(updateStatus)")
            return false
        }

        var addQuery = matchQuery
        addQuery[kSecValueData as String] = valueData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            logger.error("Tavily key SecItemAdd failed: OSStatus \(addStatus)")
            return false
        }
        return true
    }

    private static func getKeychainValue(service: String, account: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .notFound
            }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            logger.error("Tavily key SecItemCopyMatching failed: OSStatus \(status)")
            return .unavailable(status)
        }
    }

    private static func deleteKeychainValue(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Tavily key SecItemDelete failed: OSStatus \(status)")
        }
    }
}
