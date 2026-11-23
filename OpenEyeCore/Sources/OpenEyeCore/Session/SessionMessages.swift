import Foundation

/// Corps des messages de session, sans l'horodatage ajouté par `SecureChannel` (docs/protocole.md §4.3).
/// Chaque décodeur compare la taille exacte avant de lire : `bodySize` l'a déjà vérifiée, on ne s'y fie pas.
public enum SessionMessageError: Error, Equatable, Sendable {
    case badPayload
}

/// État de la capture annoncé par le Mac dans chaque Heartbeat.
public enum CaptureState: UInt8, Sendable {
    case stopped = 0
    case running = 1
    case permissionDenied = 2
    case indicatorUnavailable = 3
}

/// Motif de fermeture, envoyé dans Close et journalisé dans SESSION_CLOSED.
public enum CloseReason: UInt8, Sendable {
    case userStop = 0
    case background = 1
    case keepaliveLost = 2
    case permissionDenied = 3
    case indicatorUnavailable = 4
    case sessionExpired = 5
    case tooManyFailures = 6
    case transportLost = 7
    case error = 8
}

/// Heartbeat : état de la capture et tête du journal du Mac (docs/protocole.md §5).
public struct Heartbeat: Equatable, Sendable {
    public let captureState: CaptureState
    public let journalSeq: UInt64
    public let journalHead: Data

    public init(captureState: CaptureState, journalSeq: UInt64, journalHead: Data) {
        self.captureState = captureState
        self.journalSeq = journalSeq
        self.journalHead = journalHead
    }

    public var payload: Data {
        Data([captureState.rawValue]) + Data(FrameCodec.bigEndian(journalSeq, byteCount: 8)) + journalHead
    }

    public init(payload: Data) throws {
        let bytes = [UInt8](payload)
        guard bytes.count == 1 + 8 + 32, let state = CaptureState(rawValue: bytes[0]) else {
            throw SessionMessageError.badPayload
        }
        self.init(
            captureState: state, journalSeq: readNumber(bytes[1..<9]), journalHead: Data(bytes[9...])
        )
    }
}

public struct CloseMessage: Equatable, Sendable {
    public let reason: CloseReason

    public init(reason: CloseReason) { self.reason = reason }

    public var payload: Data { Data([reason.rawValue]) }

    /// Un motif inconnu reste une fermeture : l'appelant ferme de toute façon.
    public init(payload: Data) throws {
        guard payload.count == 1 else { throw SessionMessageError.badPayload }
        self.reason = CloseReason(rawValue: payload[payload.startIndex]) ?? .error
    }
}

/// Demande, une seule fois par session, le hash de l'entrée à la position de l'ancre.
public struct JournalAnchorRequest: Equatable, Sendable {
    public let seq: UInt64

    public init(seq: UInt64) { self.seq = seq }

    public var payload: Data { Data(FrameCodec.bigEndian(seq, byteCount: 8)) }

    public init(payload: Data) throws {
        let bytes = [UInt8](payload)
        guard bytes.count == 8 else { throw SessionMessageError.badPayload }
        self.seq = readNumber(bytes[0..<8])
    }
}

public struct JournalAnchorProof: Equatable, Sendable {
    public enum Status: UInt8, Sendable {
        case present = 0
        case purged = 1
    }

    public let seq: UInt64
    public let status: Status
    public let hash: Data

    public init(seq: UInt64, status: Status, hash: Data) {
        self.seq = seq
        self.status = status
        self.hash = hash
    }

    public var payload: Data {
        Data(FrameCodec.bigEndian(seq, byteCount: 8)) + Data([status.rawValue]) + hash
    }

    /// Un statut autre que 0 ou 1 est rejeté (docs/protocole.md §5).
    public init(payload: Data) throws {
        let bytes = [UInt8](payload)
        guard bytes.count == 8 + 1 + 32, let status = Status(rawValue: bytes[8]) else {
            throw SessionMessageError.badPayload
        }
        self.init(seq: readNumber(bytes[0..<8]), status: status, hash: Data(bytes[9...]))
    }
}

/// Lit au plus 8 octets en big-endian.
private func readNumber(_ bytes: ArraySlice<UInt8>) -> UInt64 {
    bytes.reduce(0) { ($0 << 8) | UInt64($1) }
}
