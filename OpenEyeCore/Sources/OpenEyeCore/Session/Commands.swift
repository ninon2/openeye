import CryptoKit
import Foundation

/// Commandes Verrouiller / Déverrouiller (docs/protocole.md §6, STRIDE §5 bis).
/// Chaque commande a son propre défi et sa propre signature Face ID : la signature de session ne sert pas ici (L8).
public enum CommandKind: UInt8, Sendable {
    case lock = 0x20
    case unlock = 0x21

    public var frameType: FrameType { self == .lock ? .lock : .unlock }

    public var journalEvent: JournalEvent { self == .lock ? .lock : .unlock }
}

public enum CommandError: Error, Equatable, Sendable {
    case badPayload
    /// Aucun défi en attente : commande non demandée, ou rejouée après consommation du défi (L7).
    case noChallenge
    case challengeExpired
    case challengeMismatch
    case invalidSignature
    /// Demande de défi trop rapprochée de la précédente (L6).
    case tooSoon
}

/// CmdChallenge (Mac → iPhone) : nC, 32 octets aléatoires, usage unique.
public struct CommandChallenge: Equatable, Sendable {
    public let nonce: Data

    public init(nonce: Data) { self.nonce = nonce }

    public var payload: Data { nonce }

    public init(payload: Data) throws {
        guard payload.count == 32 else { throw CommandError.badPayload }
        self.nonce = Data(payload)
    }
}

/// Lock / Unlock (iPhone → Mac) : `nC(32) ‖ duréeSecondes(4) ‖ sigP(64)`.
public struct SignedCommand: Equatable, Sendable {
    public let kind: CommandKind
    public let nonce: Data
    /// Durée demandée par le parent, telle que signée. Le Mac applique ensuite son plafond.
    public let durationSeconds: UInt32
    public let signature: Data

    static let label = "OpenEye/v1/cmd"

    /// Octets signés : `"OpenEye/v1/cmd" ‖ sessionID(8) ‖ nC(32) ‖ typ(1) ‖ duréeSecondes(4)`.
    /// Le sessionID lie la commande à la session : capturée, elle ne vaut dans aucune autre (L7).
    public static func signedBytes(
        sessionID: UInt64, nonce: Data, kind: CommandKind, durationSeconds: UInt32
    ) -> Data {
        Data(label.utf8) + Data(FrameCodec.bigEndian(sessionID, byteCount: 8)) + nonce
            + Data([kind.rawValue]) + Data(FrameCodec.bigEndian(UInt64(durationSeconds), byteCount: 4))
    }

    /// Côté iPhone. Avec la Secure Enclave, `signer.sign` demande Face ID : hors du fil principal.
    public static func make(
        _ kind: CommandKind, durationSeconds: UInt32, challenge: CommandChallenge,
        sessionID: UInt64, signer: any Signer
    ) throws -> SignedCommand {
        // Déverrouiller n'a pas de durée : un seul encodage possible pour chaque commande.
        let duration = kind == .unlock ? 0 : durationSeconds
        let signature = try signer.sign(signedBytes(
            sessionID: sessionID, nonce: challenge.nonce, kind: kind, durationSeconds: duration
        ))
        return SignedCommand(kind: kind, nonce: challenge.nonce, durationSeconds: duration, signature: signature)
    }

    init(kind: CommandKind, nonce: Data, durationSeconds: UInt32, signature: Data) {
        self.kind = kind
        self.nonce = nonce
        self.durationSeconds = durationSeconds
        self.signature = signature
    }

    public var payload: Data {
        nonce + Data(FrameCodec.bigEndian(UInt64(durationSeconds), byteCount: 4)) + signature
    }

    /// Verrouiller exige une durée non nulle, Déverrouiller une durée nulle.
    public init(_ kind: CommandKind, payload: Data) throws {
        let bytes = [UInt8](payload)
        guard bytes.count == 32 + 4 + 64 else { throw CommandError.badPayload }
        let duration = UInt32(bytes[32..<36].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        guard kind == .lock ? duration > 0 : duration == 0 else { throw CommandError.badPayload }
        self.init(kind: kind, nonce: Data(bytes[0..<32]), durationSeconds: duration, signature: Data(bytes[36...]))
    }

    public func isSigned(by parent: P256.Signing.PublicKey, sessionID: UInt64) -> Bool {
        guard let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return parent.isValidSignature(parsed, for: Self.signedBytes(
            sessionID: sessionID, nonce: nonce, kind: kind, durationSeconds: durationSeconds
        ))
    }
}

/// CmdResult (Mac → iPhone) : `résultat(1) ‖ heureFin(8)`, heure de fin en millisecondes Unix (0 si sans objet).
public struct CommandResult: Equatable, Sendable {
    public enum Status: UInt8, Sendable {
        case locked = 0
        case unlocked = 1
        case refused = 2
    }

    public let status: Status
    public let endsAt: UInt64

    public init(status: Status, endsAt: UInt64 = 0) {
        self.status = status
        self.endsAt = endsAt
    }

    public var payload: Data { Data([status.rawValue]) + Data(FrameCodec.bigEndian(endsAt, byteCount: 8)) }

    public init(payload: Data) throws {
        let bytes = [UInt8](payload)
        guard bytes.count == 1 + 8, let status = Status(rawValue: bytes[0]) else {
            throw CommandError.badPayload
        }
        self.init(status: status, endsAt: bytes[1...].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    }
}

/// Côté Mac : un seul défi en attente, valable 30 s, consommé par la première commande, bonne ou non.
/// Une instance par session : un défi ne survit jamais à sa session.
public struct CommandGate: Sendable {
    private var pending: (nonce: Data, issuedAt: ContinuousClock.Instant)?
    private var lastIssued: ContinuousClock.Instant?

    public init() {}

    public mutating func issueChallenge(now: ContinuousClock.Instant) throws -> CommandChallenge {
        if let lastIssued, lastIssued.duration(to: now) < Limits.minCommandInterval {
            throw CommandError.tooSoon
        }
        let nonce = Transcript.randomNonce()
        pending = (nonce, now)
        lastIssued = now
        return CommandChallenge(nonce: nonce)
    }

    /// Renvoie la durée effective, plafonnée par le Mac (L5). Zéro pour Déverrouiller.
    public mutating func accept(
        _ command: SignedCommand, parent: P256.Signing.PublicKey,
        sessionID: UInt64, now: ContinuousClock.Instant
    ) throws -> UInt32 {
        guard let pending else { throw CommandError.noChallenge }
        // Le défi est consommé AVANT toute vérification : une seule tentative par défi (L7).
        self.pending = nil
        guard pending.issuedAt.duration(to: now) < Limits.commandChallengeLifetime else {
            throw CommandError.challengeExpired
        }
        guard command.nonce == pending.nonce else { throw CommandError.challengeMismatch }
        guard command.isSigned(by: parent, sessionID: sessionID) else { throw CommandError.invalidSignature }
        return min(command.durationSeconds, Limits.maxLockSeconds)
    }
}
