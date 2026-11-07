import Foundation
import Security

/// Thread-safe manager for secure credentials storage in macOS Keychain.
/// Uses `kSecAttrAccessibleAfterFirstUnlock` for background reliability and security.
/// Includes an in-memory cache to prevent repetitive macOS Keychain access permission prompts.
public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager()

    private let service: String
    private let accessGroup: String?

    private let cacheLock = NSLock()
    private var inMemoryCache: [String: String] = [:]

    public enum KeychainKey: String, Sendable {
        case oauthToken = "ym_oauth_token"
        case userId = "ym_user_id"
    }

    public enum KeychainError: Error, LocalizedError, Sendable {
        case itemNotFound
        case duplicateItem
        case unexpectedStatus(OSStatus)
        case invalidDataConversion

        public var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "Item not found in Keychain."
            case .duplicateItem:
                return "Duplicate item in Keychain."
            case .unexpectedStatus(let status):
                return "Keychain error status: \(status)"
            case .invalidDataConversion:
                return "Data could not be converted to string."
            }
        }
    }

    public init(service: String = "com.yandexmusic.mac.credentials", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Generic Secure Storage Operations

    public func setString(_ value: String, for key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidDataConversion
        }
        try setData(data, for: key.rawValue)

        cacheLock.lock()
        inMemoryCache[key.rawValue] = value
        cacheLock.unlock()
    }

    public func getString(for key: KeychainKey) throws -> String? {
        cacheLock.lock()
        if let cached = inMemoryCache[key.rawValue] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let data = try getData(for: key.rawValue) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidDataConversion
        }

        cacheLock.lock()
        inMemoryCache[key.rawValue] = string
        cacheLock.unlock()

        return string
    }

    public func delete(for key: KeychainKey) throws {
        cacheLock.lock()
        inMemoryCache.removeValue(forKey: key.rawValue)
        cacheLock.unlock()

        try deleteData(for: key.rawValue)
    }

    public func clearAll() throws {
        cacheLock.lock()
        inMemoryCache.removeAll()
        cacheLock.unlock()

        try delete(for: .oauthToken)
        try delete(for: .userId)
    }

    // MARK: - Specialized Convenience API

    public func saveToken(_ token: String) throws {
        try setString(token.trimmingCharacters(in: .whitespacesAndNewlines), for: .oauthToken)
    }

    public func getToken() -> String? {
        try? getString(for: .oauthToken)
    }

    public func deleteToken() throws {
        try delete(for: .oauthToken)
    }

    public func saveUserId(_ userId: String) throws {
        try setString(userId.trimmingCharacters(in: .whitespacesAndNewlines), for: .userId)
    }

    public func getUserId() -> String? {
        try? getString(for: .userId)
    }

    public func deleteUserId() throws {
        try delete(for: .userId)
    }

    // MARK: - Low-Level Security Framework Operations

    private func makeBaseQuery(for key: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    private func setData(_ data: Data, for key: String) throws {
        var query = makeBaseQuery(for: key)
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock

        // First attempt to add
        var addQuery = query
        addQuery[kSecValueData] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Item exists, update it
            let updateQuery = makeBaseQuery(for: key)
            let attributesToUpdate: [CFString: Any] = [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus != errSecSuccess {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func getData(for key: String) throws -> Data? {
        var query = makeBaseQuery(for: key)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return item as? Data
    }

    private func deleteData(for key: String) throws {
        let query = makeBaseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
