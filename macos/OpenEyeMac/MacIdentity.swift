import CryptoKit
import Foundation
import OpenEyeCore

/// Clé d'identité du Mac : signe le handshake, l'acceptation d'appairage et le journal.
/// Secure Enclave si disponible, sinon clé logicielle dans le Keychain (décision J2, docs/protocole.md §1).
/// Aucune biométrie : le Mac doit signer sans personne devant.
struct MacSigner: Signer {
    private enum Backing {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private static let account = "mac-identity"
    private static let enclaveTag: UInt8 = 1
    private static let softwareTag: UInt8 = 2

    private let backing: Backing

    var publicKey: P256.Signing.PublicKey {
        switch backing {
        case let .enclave(key): return key.publicKey
        case let .software(key): return key.publicKey
        }
    }

    var storageDescription: String {
        switch backing {
        case .enclave: return "Secure Enclave"
        case .software: return "Keychain (clé logicielle)"
        }
    }

    func sign(_ message: Data) throws -> Data {
        switch backing {
        case let .enclave(key): return try key.signature(for: message).rawRepresentation
        case let .software(key): return try key.signature(for: message).rawRepresentation
        }
    }

    /// Recharge la clé enregistrée, ou en crée une. Le premier octet stocké indique le type de clé.
    static func loadOrCreate() throws -> MacSigner {
        if let stored = Keychain.load(account: account), let tag = stored.first {
            let blob = stored.dropFirst()
            if tag == enclaveTag, let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) {
                return MacSigner(backing: .enclave(key))
            }
            if tag == softwareTag, let key = try? P256.Signing.PrivateKey(rawRepresentation: blob) {
                return MacSigner(backing: .software(key))
            }
        }
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            // Blob chiffré par la Secure Enclave : inutilisable sur un autre Mac.
            try Keychain.save(Data([enclaveTag]) + key.dataRepresentation, account: account)
            return MacSigner(backing: .enclave(key))
        }
        let key = P256.Signing.PrivateKey()
        try Keychain.save(Data([softwareTag]) + key.rawRepresentation, account: account)
        return MacSigner(backing: .software(key))
    }
}

/// Clé publique du parent appairé. Un seul parent par Mac au MVP.
enum ParentStore {
    private static let account = "parent-identity"

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

extension P256.Signing.PublicKey {
    /// Empreinte courte, lisible, pour comparer visuellement les appareils.
    var shortFingerprint: String {
        SHA256.hash(data: x963Representation).prefix(6).map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}

/// Millisecondes Unix, horloge murale.
func wallClockMilliseconds() -> UInt64 {
    UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
}
