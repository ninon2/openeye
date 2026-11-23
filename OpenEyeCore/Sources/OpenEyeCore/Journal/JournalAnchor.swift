import Foundation

/// Ancre gardée par l'iPhone : la plus haute tête de journal vue, datée par l'horloge de l'iPhone
/// (docs/protocole.md §5). Elle détecte une troncature ou une purge anticipée du journal du Mac (T4).
public struct JournalAnchor: Equatable, Codable, Sendable {
    public let seq: UInt64
    public let hash: Data
    /// Millisecondes Unix, horloge de l'iPhone.
    public let receivedAt: UInt64

    public init(seq: UInt64, hash: Data, receivedAt: UInt64) {
        self.seq = seq
        self.hash = hash
        self.receivedAt = receivedAt
    }
}

/// Conclusion affichée au parent après la vérification de l'ancre.
public enum AnchorVerdict: Equatable, Sendable {
    case consistent
    case purgedNormally
    case altered
    case impossibleClockChanged
    case impossibleNoAnswer

    /// Seules ces deux conclusions autorisent à remplacer l'ancre sans confirmation du parent.
    public var allowsReplacement: Bool { self == .consistent || self == .purgedNormally }
}

public enum AnchorCheck {
    /// Le premier Heartbeat seul suffit à détecter un journal plus court que l'ancre.
    public static func headIsBehind(anchor: JournalAnchor, heartbeat: Heartbeat) -> Bool {
        heartbeat.journalSeq < anchor.seq
    }

    /// - Precondition: `proof.seq == anchor.seq`, vérifié par l'appelant qui rejette et compte sinon.
    public static func evaluate(anchor: JournalAnchor, proof: JournalAnchorProof, now: UInt64) -> AnchorVerdict {
        switch proof.status {
        case .present:
            return proof.hash == anchor.hash ? .consistent : .altered
        case .purged:
            guard now >= anchor.receivedAt else { return .impossibleClockChanged }
            // Moins de 29 jours : une purge normale (30 jours) est impossible.
            return now - anchor.receivedAt < Limits.minPurgedAnchorAgeMilliseconds ? .altered : .purgedNormally
        }
    }
}
