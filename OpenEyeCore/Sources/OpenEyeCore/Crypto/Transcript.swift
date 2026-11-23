import CryptoKit
import Foundation

/// Encodage canonique et hachage (docs/protocole.md §3 et §7).
enum Transcript {
    /// Libellés de séparation de domaine : une signature faite pour un usage ne vaut pour aucun autre.
    static let sessionLabel = "OpenEye/v1/session"
    static let macSignatureLabel = "OpenEye/v1/sess-mac"
    static let parentSignatureLabel = "OpenEye/v1/sess-parent"
    static let macToIPhoneKeyLabel = "OpenEye/v1/key/mac->iphone"
    static let iPhoneToMacKeyLabel = "OpenEye/v1/key/iphone->mac"
    static let sessionIDLabel = "OpenEye/v1/sid"

    /// lp(x) : longueur sur 2 octets, puis x. Sans elle, "ab"‖"c" et "a"‖"bc" auraient le même hash.
    static func lengthPrefixed(_ field: Data) -> Data {
        precondition(field.count <= Int(UInt16.max), "champ interne trop long")
        return Data(FrameCodec.bigEndian(UInt64(field.count), byteCount: 2)) + field
    }

    static func labeled(_ label: String, _ data: Data) -> Data {
        Data(label.utf8) + data
    }

    /// TH : hash de toute la négociation. Les clés publiques sont en x963 (65 octets).
    static func session(
        macIdentity: Data, parentIdentity: Data,
        iPhoneEphemeral: Data, iPhoneNonce: Data,
        macEphemeral: Data, macNonce: Data
    ) -> Data {
        var bytes = Data(sessionLabel.utf8)
        for field in [macIdentity, parentIdentity, iPhoneEphemeral, iPhoneNonce, macEphemeral, macNonce] {
            bytes += lengthPrefixed(field)
        }
        return Data(SHA256.hash(data: bytes))
    }

    /// 32 octets du générateur cryptographique de CryptoKit.
    static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
