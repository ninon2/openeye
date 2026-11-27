import Foundation
import Security

/// Petites entrées secrètes ou d'identité, jamais synchronisées (docs/architecture.md §5).
enum Keychain {
    private static let service = "fr.openeye.m2.macos"

    enum Failure: Error {
        case status(OSStatus)
    }

    static func save(_ data: Data, account: String) throws {
        delete(account: account)
        var item = query(account: account, dataProtection: true)
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(item as CFDictionary, nil)
        // Sans équipe de signature, le trousseau « data protection » est refusé (-34018) :
        // on se replie sur le trousseau de session, toujours local à ce Mac.
        if status == errSecMissingEntitlement {
            item = query(account: account, dataProtection: false)
            item[kSecValueData] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    static func load(account: String) -> Data? {
        for dataProtection in [true, false] {
            var search = query(account: account, dataProtection: dataProtection)
            search[kSecReturnData] = true
            var found: CFTypeRef?
            if SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess, let data = found as? Data {
                return data
            }
        }
        return nil
    }

    static func delete(account: String) {
        for dataProtection in [true, false] {
            SecItemDelete(query(account: account, dataProtection: dataProtection) as CFDictionary)
        }
    }

    private static func query(account: String, dataProtection: Bool) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: dataProtection,
        ]
    }
}
