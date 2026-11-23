import CryptoKit
import Foundation

public enum PairingError: Error, Equatable, Sendable {
    /// Objet déjà utilisé, étape dans le désordre, ou échec précédent.
    case invalidState
    case invalidQR
    case expired
    case wrongPairing
    case invalidKey
    case invalidMAC
    case invalidCommitment
    case invalidSignature
    case refusedByUser
}

/// Contenu du QR affiché par le Mac (docs/protocole.md §2.1). Contient un secret : ne jamais le journaliser.
public struct QRPayload {
    static let version: UInt8 = 0x01
    static let size = 1 + 16 + 32 + 8 + 65
    /// Longueur exacte de `size` octets en base64url sans remplissage.
    static let textLength = 163

    let pairingID: Data
    let secret: SymmetricKey
    /// Secondes Unix.
    let expiry: UInt64
    let macIdentity: P256.Signing.PublicKey

    /// Texte à afficher dans le QR.
    public var text: String {
        let bytes = Data([Self.version]) + pairingID + secret.withUnsafeBytes { Data($0) }
            + Data(FrameCodec.bigEndian(expiry, byteCount: 8)) + macIdentity.x963Representation
        return Self.base64URL(bytes)
    }

    init(pairingID: Data, secret: SymmetricKey, expiry: UInt64, macIdentity: P256.Signing.PublicKey) {
        self.pairingID = pairingID
        self.secret = secret
        self.expiry = expiry
        self.macIdentity = macIdentity
    }

    /// Un QR est une donnée hostile : n'importe qui peut en imprimer un.
    /// - Parameter now: heure de l'iPhone, en secondes Unix.
    public init(text: String, now: UInt64) throws {
        guard text.utf8.count == Self.textLength else { throw PairingError.invalidQR }
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: standard), bytes.count == Self.size,
              // Une seule écriture acceptée par contenu.
              Self.base64URL(bytes) == text,
              bytes[0] == Self.version
        else { throw PairingError.invalidQR }

        let expiry = bytes[49..<57].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard now < expiry else { throw PairingError.expired }
        // Une durée anormalement longue est refusée, à la tolérance d'horloge près.
        guard expiry - now <= Limits.pairingLifetimeSeconds + Limits.clockToleranceMilliseconds / 1_000 else {
            throw PairingError.invalidQR
        }
        guard let macIdentity = try? P256.Signing.PublicKey(x963Representation: Data(bytes[57..<122])) else {
            throw PairingError.invalidKey
        }
        self.init(
            pairingID: Data(bytes[1..<17]), secret: SymmetricKey(data: Data(bytes[17..<49])),
            expiry: expiry, macIdentity: macIdentity
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
