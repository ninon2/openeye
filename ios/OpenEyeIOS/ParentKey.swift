import CryptoKit
import Foundation
import LocalAuthentication
import OpenEyeCore
import Security

/// Petites entrées du Keychain, liées à cet iPhone et jamais synchronisées (docs/architecture.md §5).
enum Keychain {
    private static let service = "fr.openeye.m2.ios"

    enum Failure: Error {
        case status(OSStatus)
    }

    /// Sans code de déverrouillage, rien n'est lisible. Le simulateur n'a pas de code : repli pour les essais.
    private static var accessibility: CFString {
        #if targetEnvironment(simulator)
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        #endif
    }

    static func save(_ data: Data, account: String) throws {
        delete(account: account)
        var item = query(account: account)
        item[kSecValueData] = data
        item[kSecAttrAccessible] = accessibility
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    static func load(account: String) -> Data? {
        var search = query(account: account)
        search[kSecReturnData] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    private static func query(account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}

enum ParentKeyError: Error {
    case secureEnclaveUnavailable
    case accessControl
    case missingKey
}

/// Clé du parent : générée DANS la Secure Enclave, utilisable seulement après Face ID,
/// invalidée si un visage est ajouté (`.biometryCurrentSet`), sans repli sur le code (docs/choix-crypto.md).
/// Seul le blob chiffré par la puce est stocké dans le Keychain.
struct ParentSigner: Signer {
    private static let account = "parent-key"

    let publicKey: P256.Signing.PublicKey
    private let blob: Data
    private let reason: String

    /// Chaque appel demande Face ID : ne jamais l'appeler depuis le fil principal.
    func sign(_ message: Data) throws -> Data {
        #if targetEnvironment(simulator)
        // Simulateur (essais uniquement) : pas de Secure Enclave. Face ID simulé, puis clé logicielle.
        try Self.simulatedFaceID(reason: reason)
        let key = try P256.Signing.PrivateKey(rawRepresentation: blob)
        return try key.signature(for: message).rawRepresentation
        #else
        // Contexte neuf et durée de réutilisation nulle : Face ID à chaque signature.
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = "" // pas de bouton « Saisir le code »
        context.localizedReason = reason
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        return try key.signature(for: message).rawRepresentation
        #endif
    }

    func withReason(_ reason: String) -> ParentSigner {
        ParentSigner(publicKey: publicKey, blob: blob, reason: reason)
    }

    static func load() -> ParentSigner? {
        guard let stored = Keychain.load(account: account) else { return nil }
        #if targetEnvironment(simulator)
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: stored) else { return nil }
        return ParentSigner(publicKey: key.publicKey, blob: stored, reason: "")
        #else
        // Lire la clé publique ne demande pas Face ID : seule la signature l'exige.
        guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored) else { return nil }
        return ParentSigner(publicKey: key.publicKey, blob: stored, reason: "")
        #endif
    }

    /// Nouvelle clé pour un nouvel appairage : l'ancienne est détruite.
    static func create() throws -> ParentSigner {
        #if targetEnvironment(simulator)
        let key = P256.Signing.PrivateKey()
        try Keychain.save(key.rawRepresentation, account: account)
        return ParentSigner(publicKey: key.publicKey, blob: key.rawRepresentation, reason: "")
        #else
        guard SecureEnclave.isAvailable else { throw ParentKeyError.secureEnclaveUnavailable }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil
        ) else { throw ParentKeyError.accessControl }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        try Keychain.save(key.dataRepresentation, account: account)
        return ParentSigner(publicKey: key.publicKey, blob: key.dataRepresentation, reason: "")
        #endif
    }

    static func delete() {
        Keychain.delete(account: account)
    }

    #if targetEnvironment(simulator)
    private static func simulatedFaceID(reason: String) throws {
        let context = LAContext()
        var result: Result<Void, Error> = .failure(LAError(.authenticationFailed))
        let done = DispatchSemaphore(value: 0)
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
            result = ok ? .success(()) : .failure(error ?? LAError(.authenticationFailed))
            done.signal()
        }
        done.wait()
        try result.get()
    }
    #endif
}

/// Clé publique du Mac appairé, apprise par le QR et confirmée par sa signature.
enum MacStore {
    private static let account = "mac-identity"

    static func load() -> P256.Signing.PublicKey? {
        Keychain.load(account: account).flatMap { try? P256.Signing.PublicKey(x963Representation: $0) }
    }

    static func save(_ key: P256.Signing.PublicKey) throws {
        try Keychain.save(key.x963Representation, account: account)
    }

    static func delete() {
        Keychain.delete(account: account)
    }
}

/// Ancre du journal du Mac, liée à cet appairage et supprimée avec lui (docs/protocole.md §5).
enum AnchorStore {
    private static let account = "journal-anchor"

    static func load() -> JournalAnchor? {
        Keychain.load(account: account).flatMap { try? JSONDecoder().decode(JournalAnchor.self, from: $0) }
    }

    static func save(_ anchor: JournalAnchor) {
        if let data = try? JSONEncoder().encode(anchor) { try? Keychain.save(data, account: account) }
    }

    static func delete() {
        Keychain.delete(account: account)
    }
}

extension P256.Signing.PublicKey {
    var shortFingerprint: String {
        SHA256.hash(data: x963Representation).prefix(6).map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}

func wallClockMilliseconds() -> UInt64 {
    UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
}
