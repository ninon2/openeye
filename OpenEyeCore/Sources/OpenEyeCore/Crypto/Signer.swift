import CryptoKit
import Foundation

/// « Signe ces octets. » Sur l'iPhone, l'implémentation utilise la Secure Enclave et Face ID (tâche 22).
/// L'appel peut donc bloquer : ne jamais l'appeler depuis le fil principal.
public protocol Signer {
    var publicKey: P256.Signing.PublicKey { get }
    /// Signature ECDSA P-256 au format brut (64 octets). Lève une erreur si Face ID est annulé.
    func sign(_ message: Data) throws -> Data
}
