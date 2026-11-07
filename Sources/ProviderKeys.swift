import Foundation
import Security

enum ProviderKeys {
    private struct KeyError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private static func query(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.worktrees.dudewheresmydisk.ai",
         kSecAttrAccount as String: provider.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw KeyError("Keychain: " + message)
        }
    }

    static func exists(_ provider: AIProvider) throws -> Bool {
        let status = SecItemCopyMatching(query(provider) as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    static func read(_ provider: AIProvider) throws -> String? {
        var match = query(provider)
        match[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(match as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let bytes = result as? Data, let key = String(data: bytes, encoding: .utf8), !key.isEmpty else {
            throw KeyError("Replace the unreadable API key in AI Settings.")
        }
        return key
    }

    static func save(_ key: String, for provider: AIProvider) throws {
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 4096, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw KeyError("Enter the API key without spaces or line breaks.")
        }
        let match = query(provider)
        let bytes = Data(token.utf8)
        var item = match
        item[kSecValueData as String] = bytes
        item[kSecAttrLabel as String] = "Dude, Where’s My Disk? · " + provider.title
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(match as CFDictionary, [kSecValueData as String: bytes] as CFDictionary))
        } else {
            try check(status)
        }
    }

    static func remove(_ provider: AIProvider) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}
