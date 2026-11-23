import CryptoKit
import Foundation

/// Événements journalisés, et rien d'autre (docs/journal.md §2).
public enum JournalEvent: UInt8, CaseIterable, Sendable {
    case appStarted = 0x01
    case paired = 0x02
    case revoked = 0x03
    case sessionOpened = 0x04
    case sessionClosed = 0x05
    case captureStarted = 0x06
    case captureStopped = 0x07
    case permissionDenied = 0x08
    case authFailures = 0x09
    case purgeCheckpoint = 0x0A
    case lock = 0x20
    case unlock = 0x21

    /// Taille exacte des données complémentaires.
    var dataSize: Int {
        switch self {
        case .lock, .unlock: return 8 + 4 + 32 + 64
        case .appStarted, .permissionDenied: return 0
        case .paired: return 65
        case .revoked: return 32
        case .sessionOpened: return 8 + 32 + 64
        case .sessionClosed: return 8 + 1
        case .captureStarted, .captureStopped: return 8
        case .authFailures: return 2
        case .purgeCheckpoint: return 8 + 32 + 1 + 65
        }
    }
}

public enum JournalError: Error, Equatable, Sendable {
    /// Le fichier ne se découpe pas en entrées valides. Position 1-indexée de l'entrée fautive.
    case malformed(position: Int)
    case badData
}

/// Une entrée : `corps = seq(8) ‖ ts(8) ‖ code(1) ‖ dataLen(2) ‖ data ‖ prevHash(32)`, puis `sig(64)`.
public struct JournalEntry: Equatable, Sendable {
    public let seq: UInt64
    /// Millisecondes Unix, horloge du Mac.
    public let timestamp: UInt64
    public let event: JournalEvent
    public let data: Data
    public let prevHash: Data
    public let signature: Data

    static let hashLabel = "OpenEye/v1/journal"
    static let fixedSize = 8 + 8 + 1 + 2 + 32 + 64

    var body: Data {
        Data(FrameCodec.bigEndian(seq, byteCount: 8)) + Data(FrameCodec.bigEndian(timestamp, byteCount: 8))
            + Data([event.rawValue]) + Data(FrameCodec.bigEndian(UInt64(data.count), byteCount: 2))
            + data + prevHash
    }

    /// Hash calculé sur le format binaire canonique, jamais sur un export lisible.
    public var hash: Data { Data(SHA256.hash(data: Data(Self.hashLabel.utf8) + body)) }

    var encoded: Data { body + signature }

    /// Identifiant de session pour les événements qui en portent un.
    public var sessionID: UInt64? {
        switch event {
        case .sessionOpened, .sessionClosed, .captureStarted, .captureStopped, .lock, .unlock:
            return data.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        default:
            return nil
        }
    }
}

/// Résultat de la vérification, affiché à l'enfant comme au parent (US 29).
public enum JournalVerification: Equatable, Sendable {
    case valid(entries: Int)
    /// Premier échec, position 1-indexée dans le fichier.
    case altered(position: Int)
}

/// Journal signé par le Mac et chaîné par SHA-256 (docs/journal.md).
/// À utiliser depuis une seule file d'exécution.
public struct JournalChain: Sendable {
    public private(set) var entries: [JournalEntry] = []

    public init() {}

    /// Lit un fichier. Toute incohérence de forme est refusée : la vérification ne porte que sur un fichier bien formé.
    public init(encoded: Data) throws {
        let bytes = [UInt8](encoded)
        var offset = 0
        while offset < bytes.count {
            let position = entries.count + 1
            // seq, ts, code et dataLen sont lus seulement si les 19 premiers octets existent.
            guard bytes.count - offset >= JournalEntry.fixedSize,
                  let event = JournalEvent(rawValue: bytes[offset + 16])
            else { throw JournalError.malformed(position: position) }
            let dataLength = Int(bytes[offset + 17]) << 8 | Int(bytes[offset + 18])
            guard dataLength == event.dataSize, bytes.count - offset >= JournalEntry.fixedSize + dataLength else {
                throw JournalError.malformed(position: position)
            }
            let dataStart = offset + 19
            let hashStart = dataStart + dataLength
            entries.append(JournalEntry(
                seq: readNumber(bytes[offset..<offset + 8]),
                timestamp: readNumber(bytes[offset + 8..<offset + 16]),
                event: event,
                data: Data(bytes[dataStart..<hashStart]),
                prevHash: Data(bytes[hashStart..<hashStart + 32]),
                signature: Data(bytes[hashStart + 32..<hashStart + 96])
            ))
            offset = hashStart + 96
        }
    }

    public var encoded: Data { entries.reduce(into: Data()) { $0 += $1.encoded } }

    /// Tête transmise dans chaque Heartbeat : seq 0 et 32 zéros pour un journal vide.
    public var head: (seq: UInt64, hash: Data) {
        guard let last = entries.last else { return (0, Data(count: 32)) }
        return (last.seq, last.hash)
    }

    /// Ajoute et signe une entrée. `data` doit avoir la taille exacte du type.
    @discardableResult
    public mutating func append(
        _ event: JournalEvent, data: Data = Data(), timestamp: UInt64, signer: any Signer
    ) throws -> JournalEntry {
        guard data.count == event.dataSize else { throw JournalError.badData }
        let (seq, prevHash) = head
        let unsigned = JournalEntry(
            seq: seq + 1, timestamp: timestamp, event: event, data: data, prevHash: prevHash, signature: Data()
        )
        let entry = JournalEntry(
            seq: unsigned.seq, timestamp: timestamp, event: event, data: data, prevHash: prevHash,
            signature: try signer.sign(unsigned.hash)
        )
        entries.append(entry)
        return entry
    }

    /// Réponse à JournalAnchorRequest (docs/protocole.md §5).
    public func anchorProof(seq: UInt64) -> JournalAnchorProof {
        if let entry = entries.first(where: { $0.seq == seq }) {
            return JournalAnchorProof(seq: seq, status: .present, hash: entry.hash)
        }
        if let first = entries.first, seq < first.seq {
            return JournalAnchorProof(seq: seq, status: .purged, hash: Data(count: 32))
        }
        // Position au-delà de la tête : le journal a été raccourci. Aucun hash ne peut correspondre.
        return JournalAnchorProof(seq: seq, status: .present, hash: Data(count: 32))
    }

    /// Retire les entrées de plus de 30 jours, sans trou, puis ajoute PURGE_CHECKPOINT (docs/journal.md §6).
    /// L'appelant écrit ensuite le fichier en un remplacement atomique.
    public mutating func purge(now: UInt64, signer: any Signer) throws {
        let cutoff = now >= Limits.journalRetentionMilliseconds ? now - Limits.journalRetentionMilliseconds : 0
        let count = entries.prefix { $0.timestamp < cutoff }.count
        guard count > 0 else { return }
        let removed = Array(entries.prefix(count))
        guard let last = removed.last else { return }

        // Clé du parent en vigueur juste après la dernière entrée purgée : sans elle, les sigP conservées
        // deviendraient invérifiables (R1).
        var key = Self.startingParent(of: entries)
        for entry in removed { key = Self.nextParent(after: entry, current: key) }

        entries.removeFirst(count)
        let keyBytes = key.map { $0.x963Representation } ?? Data(count: 65)
        let data = Data(FrameCodec.bigEndian(last.seq, byteCount: 8)) + last.hash
            + Data([key == nil ? 0 : 1]) + keyBytes
        // Le checkpoint se chaîne à la fin du journal conservé. Si tout est purgé, il suit l'entrée purgée.
        if entries.isEmpty {
            let unsigned = JournalEntry(
                seq: last.seq + 1, timestamp: now, event: .purgeCheckpoint, data: data,
                prevHash: last.hash, signature: Data()
            )
            entries.append(JournalEntry(
                seq: unsigned.seq, timestamp: now, event: .purgeCheckpoint, data: data,
                prevHash: last.hash, signature: try signer.sign(unsigned.hash)
            ))
        } else {
            try append(.purgeCheckpoint, data: data, timestamp: now, signer: signer)
        }
    }

    // MARK: - Vérification

    /// Vérifie seq, chaînage, hash, signature du Mac, et les preuves du parent (docs/journal.md §4).
    public static func verify(_ entries: [JournalEntry], macIdentity: P256.Signing.PublicKey) -> JournalVerification {
        guard !entries.isEmpty else { return .valid(entries: 0) }

        // Point de départ : le checkpoint le plus récent, ou le début d'un journal jamais purgé.
        var expectedSeq: UInt64
        var expectedPrev: Data
        var parent: P256.Signing.PublicKey?
        if let checkpoint = entries.last(where: { $0.event == .purgeCheckpoint }) {
            guard let start = Checkpoint(checkpoint.data) else {
                return .altered(position: (entries.firstIndex(of: checkpoint) ?? 0) + 1)
            }
            expectedSeq = start.seq + 1
            expectedPrev = start.hash
            parent = start.parent
        } else {
            expectedSeq = 1
            expectedPrev = Data(count: 32)
            parent = nil
        }

        for (index, entry) in entries.enumerated() {
            let position = index + 1
            guard entry.seq == expectedSeq, entry.prevHash == expectedPrev,
                  isValid(entry.signature, of: entry.hash, with: macIdentity)
            else { return .altered(position: position) }

            switch entry.event {
            case .sessionOpened:
                // La preuve du parent se vérifie avec la clé EN VIGUEUR à cette position.
                guard let key = parent,
                      isValid(Data(entry.data.suffix(64)),
                              of: Transcript.labeled(Transcript.parentSignatureLabel, Data(entry.data.dropFirst(8).prefix(32))),
                              with: key)
                else { return .altered(position: position) }
            case .lock, .unlock:
                // L3 : la commande signée par le parent se revérifie à partir de l'entrée seule.
                guard let key = parent, let command = JournalData.command(from: entry),
                      command.signedCommand.isSigned(by: key, sessionID: command.sessionID)
                else { return .altered(position: position) }
            case .paired:
                guard (try? P256.Signing.PublicKey(x963Representation: entry.data)) != nil else {
                    return .altered(position: position)
                }
            case .purgeCheckpoint:
                guard Checkpoint(entry.data) != nil else { return .altered(position: position) }
            default:
                break
            }
            parent = nextParent(after: entry, current: parent)
            expectedSeq = entry.seq + 1
            expectedPrev = entry.hash
        }
        return .valid(entries: entries.count)
    }

    // MARK: - Aides

    private struct Checkpoint {
        let seq: UInt64
        let hash: Data
        let parent: P256.Signing.PublicKey?

        init?(_ data: Data) {
            let bytes = [UInt8](data)
            guard bytes.count == 106, bytes[40] <= 1 else { return nil }
            seq = readNumber(bytes[0..<8])
            hash = Data(bytes[8..<40])
            if bytes[40] == 1 {
                guard let key = try? P256.Signing.PublicKey(x963Representation: Data(bytes[41..<106])) else {
                    return nil
                }
                parent = key
            } else {
                guard bytes[41...].allSatisfy({ $0 == 0 }) else { return nil }
                parent = nil
            }
        }
    }

    private static func startingParent(of entries: [JournalEntry]) -> P256.Signing.PublicKey? {
        entries.last(where: { $0.event == .purgeCheckpoint }).flatMap { Checkpoint($0.data)?.parent }
    }

    /// PAIRED remplace la clé du parent, REVOKED la supprime.
    private static func nextParent(
        after entry: JournalEntry, current: P256.Signing.PublicKey?
    ) -> P256.Signing.PublicKey? {
        switch entry.event {
        case .paired: return try? P256.Signing.PublicKey(x963Representation: entry.data)
        case .revoked: return nil
        default: return current
        }
    }

    private static func isValid(_ signature: Data, of message: Data, with key: P256.Signing.PublicKey) -> Bool {
        guard let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(parsed, for: message)
    }
}

/// Données complémentaires, construites ici pour garder un seul encodeur.
public enum JournalData {
    public static func paired(parent: P256.Signing.PublicKey) -> Data { parent.x963Representation }

    public static func revoked(parent: P256.Signing.PublicKey) -> Data {
        Data(SHA256.hash(data: parent.x963Representation))
    }

    public static func sessionOpened(sessionID: UInt64, transcriptHash: Data, parentSignature: Data) -> Data {
        Data(FrameCodec.bigEndian(sessionID, byteCount: 8)) + transcriptHash + parentSignature
    }

    public static func sessionClosed(sessionID: UInt64, reason: CloseReason) -> Data {
        Data(FrameCodec.bigEndian(sessionID, byteCount: 8)) + Data([reason.rawValue])
    }

    public static func capture(sessionID: UInt64) -> Data {
        Data(FrameCodec.bigEndian(sessionID, byteCount: 8))
    }

    public static func authFailures(count: Int) -> Data {
        Data(FrameCodec.bigEndian(UInt64(min(count, Int(UInt16.max))), byteCount: 2))
    }

    /// LOCK / UNLOCK : `sessionID(8) ‖ durée(4) ‖ nC(32) ‖ sigP(64)`, durée telle que signée par le parent.
    public static func command(_ command: SignedCommand, sessionID: UInt64) -> Data {
        Data(FrameCodec.bigEndian(sessionID, byteCount: 8))
            + Data(FrameCodec.bigEndian(UInt64(command.durationSeconds), byteCount: 4))
            + command.nonce + command.signature
    }

    /// Relit la commande d'une entrée LOCK ou UNLOCK.
    static func command(from entry: JournalEntry) -> (sessionID: UInt64, signedCommand: SignedCommand)? {
        guard let sessionID = entry.sessionID, entry.data.count == entry.event.dataSize else { return nil }
        let kind: CommandKind
        switch entry.event {
        case .lock: kind = .lock
        case .unlock: kind = .unlock
        default: return nil
        }
        let bytes = [UInt8](entry.data)
        let payload = Data(bytes[12..<44]) + Data(bytes[8..<12]) + Data(bytes[44...])
        guard let command = try? SignedCommand(kind, payload: payload) else { return nil }
        return (sessionID, command)
    }
}

private func readNumber(_ bytes: ArraySlice<UInt8>) -> UInt64 {
    bytes.reduce(0) { ($0 << 8) | UInt64($1) }
}
