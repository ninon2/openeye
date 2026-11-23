import Foundation

/// Motif de rejet. Usage local uniquement : il n'est jamais envoyé au pair
/// et ne contient aucun octet du paquet (pas de donnée dans les logs).
public enum FrameError: Error, Equatable, Sendable {
    case badPacketSize
    case badMagic
    case badVersion
    case unknownType
    case wrongDirection
    case unexpectedType
    case badLength
    case badBodySize
    case badClearHeader
    case badCounter
    case badTagSize
}

/// En-tête de 24 octets, entiers en big-endian (docs/protocole.md §4.1).
public struct FrameHeader: Equatable, Sendable {
    public let type: FrameType
    public let sessionID: UInt64
    public let counter: UInt64
    public let bodyLength: Int

    /// Refuse de construire un en-tête que le récepteur devrait rejeter.
    public init(type: FrameType, sessionID: UInt64, counter: UInt64, bodyLength: Int) throws {
        guard type.bodySize.contains(bodyLength) else { throw FrameError.badBodySize }
        if type.isEncrypted {
            // Le compteur d'une session commence à 1.
            guard counter >= 1 else { throw FrameError.badCounter }
        } else {
            guard sessionID == 0, counter == 0 else { throw FrameError.badClearHeader }
        }
        self.type = type
        self.sessionID = sessionID
        self.counter = counter
        self.bodyLength = bodyLength
    }

    /// Octets exacts de l'en-tête. Ils servent aussi de donnée associée (AAD) à AES-GCM.
    public var encoded: Data {
        var data = Data(FrameCodec.magic)
        data.append(FrameCodec.version)
        data.append(type.rawValue)
        data.append(contentsOf: FrameCodec.bigEndian(sessionID, byteCount: 8))
        data.append(contentsOf: FrameCodec.bigEndian(counter, byteCount: 8))
        data.append(contentsOf: FrameCodec.bigEndian(UInt64(bodyLength), byteCount: 4))
        return data
    }
}

/// Paquet dont la FORME est valide. Pour un type chiffré, rien n'est encore authentifié :
/// la session, le compteur et le tag sont vérifiés ensuite par SecureChannel (tâche 23).
public struct Frame: Equatable, Sendable {
    public let header: FrameHeader
    /// Corps en clair (type < 0x10) ou chiffré (type ≥ 0x10).
    public let body: Data
    /// 16 octets pour un type chiffré, vide sinon.
    public let tag: Data
}

/// Étapes 1 à 4 de la réception (docs/protocole.md §4.4).
public enum FrameCodec {
    static let magic: [UInt8] = [0x4F, 0x45] // "OE"
    static let version: UInt8 = 0x01

    /// - Parameters:
    ///   - sender: l'appareil en face, déduit de notre rôle et jamais lu dans le paquet.
    ///   - allowed: les types attendus dans l'état courant.
    public static func decode(_ packet: Data, from sender: Sender, allowed: Set<FrameType>) throws -> Frame {
        // Étape 1 : la taille, avant toute copie.
        guard packet.count >= Limits.headerSize, packet.count <= Limits.maxPacketSize else {
            throw FrameError.badPacketSize
        }
        // Un `Data` peut être une tranche dont les indices ne commencent pas à 0 : on normalise.
        let bytes = [UInt8](packet)

        // Étape 2 : magic et version.
        guard bytes[0] == magic[0], bytes[1] == magic[1] else { throw FrameError.badMagic }
        guard bytes[2] == version else { throw FrameError.badVersion }

        // Étape 3 : type connu, dans le bon sens, attendu maintenant.
        guard let type = FrameType(rawValue: bytes[3]) else { throw FrameError.unknownType }
        guard type.canBeSent(by: sender) else { throw FrameError.wrongDirection }
        guard allowed.contains(type) else { throw FrameError.unexpectedType }

        // Étape 4 : la longueur annoncée doit correspondre à la taille réelle.
        // On compare sans jamais utiliser la valeur annoncée pour découper ou allouer.
        let tagSize = type.isEncrypted ? Limits.tagSize : 0
        let bodyLength = bytes.count - Limits.headerSize - tagSize
        guard bodyLength >= 0, readBigEndian(bytes[20..<24]) == UInt64(bodyLength) else {
            throw FrameError.badLength
        }

        let header = try FrameHeader(
            type: type,
            sessionID: readBigEndian(bytes[4..<12]),
            counter: readBigEndian(bytes[12..<20]),
            bodyLength: bodyLength
        )
        let bodyEnd = Limits.headerSize + bodyLength
        return Frame(
            header: header,
            body: Data(bytes[Limits.headerSize..<bodyEnd]),
            tag: Data(bytes[bodyEnd...])
        )
    }

    /// Assemble un paquet. Pour un type chiffré, `body` est le texte chiffré.
    public static func encode(header: FrameHeader, body: Data, tag: Data = Data()) throws -> Data {
        guard body.count == header.bodyLength else { throw FrameError.badLength }
        guard tag.count == (header.type.isEncrypted ? Limits.tagSize : 0) else { throw FrameError.badTagSize }
        return header.encoded + body + tag
    }

    static func bigEndian(_ value: UInt64, byteCount: Int) -> [UInt8] {
        (0..<byteCount).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }

    /// Lit au plus 8 octets : le décalage ne peut pas déborder d'un UInt64.
    private static func readBigEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
