import CryptoKit
import Foundation

/// Clés d'une session : une par sens, jamais écrites sur le disque.
struct SessionKeys {
    let macToIPhone: SymmetricKey
    let iPhoneToMac: SymmetricKey
    let sessionID: UInt64

    static func derive(
        ephemeral: P256.KeyAgreement.PrivateKey,
        peerEphemeral: P256.KeyAgreement.PublicKey,
        transcriptHash: Data
    ) throws -> SessionKeys {
        // ECDH : les deux appareils obtiennent le même secret sans l'avoir transmis.
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral)

        // HKDF : le secret brut n'est jamais utilisé comme clé. Le sel lie les clés à CETTE négociation.
        func key(_ label: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: transcriptHash,
                sharedInfo: Data(label.utf8), outputByteCount: 32
            )
        }

        let digest = SHA256.hash(data: Transcript.labeled(Transcript.sessionIDLabel, transcriptHash))
        return SessionKeys(
            macToIPhone: key(Transcript.macToIPhoneKeyLabel),
            iPhoneToMac: key(Transcript.iPhoneToMacKeyLabel),
            sessionID: digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        )
    }
}
