/// Appareil qui émet un paquet.
public enum Sender: Sendable {
    case mac
    case iphone
}

/// Types de paquets (docs/protocole.md §4.3).
/// Les types 0x20–0x23 (extension J4) sont absents : ils sont donc refusés comme inconnus.
public enum FrameType: UInt8, CaseIterable, Sendable {
    case pairRequest = 0x01
    case pairNonce = 0x02
    case pairReveal = 0x03
    case pairAccept = 0x04
    case hello = 0x05
    case challenge = 0x06
    case auth = 0x07
    case reject = 0x08

    case sessionReady = 0x10
    case heartbeat = 0x11
    case videoParams = 0x12
    case videoFragment = 0x13
    case keepalive = 0x14
    case close = 0x15
    case journalAnchorRequest = 0x16
    case journalAnchorProof = 0x17

    /// À partir de 0x10, le corps est chiffré et suivi d'un tag.
    public var isEncrypted: Bool { rawValue >= 0x10 }

    /// Vrai si `sender` a le droit d'émettre ce type.
    /// Le `switch` n'a pas de `default` : un nouveau type ne compile pas tant que son sens n'est pas décidé.
    public func canBeSent(by sender: Sender) -> Bool {
        switch self {
        case .pairRequest, .pairReveal, .hello, .auth, .keepalive, .journalAnchorRequest:
            return sender == .iphone
        case .pairNonce, .pairAccept, .challenge, .reject, .sessionReady, .heartbeat,
             .videoParams, .videoFragment, .journalAnchorProof:
            return sender == .mac
        case .close:
            return true
        }
    }

    /// Tailles de corps acceptées. AES-GCM conserve la taille : la règle vaut avant et après déchiffrement.
    public var bodySize: ClosedRange<Int> {
        switch self {
        case .pairRequest: return exactly(16 + 65 + 32 + 32)
        case .pairNonce: return exactly(16 + 32)
        case .pairReveal: return exactly(16 + 32 + 64)
        case .pairAccept: return exactly(16 + 64)
        case .hello: return exactly(32 + 65 + 32)
        case .challenge: return exactly(65 + 32 + 64)
        case .auth: return exactly(64)
        case .reject: return exactly(1)
        case .sessionReady, .keepalive: return exactly(8)
        case .heartbeat: return exactly(8 + 1 + 8 + 32)
        case .close: return exactly(8 + 1)
        case .journalAnchorRequest: return exactly(8 + 8)
        case .journalAnchorProof: return exactly(8 + 8 + 1 + 32)
        case .videoParams:
            // ts, width, height, spsLen, au moins 1 octet de SPS, ppsLen, au moins 1 octet de PPS.
            return (8 + 2 + 2 + 2 + 1 + 2 + 1)...Limits.maxVideoParamsBody
        case .videoFragment:
            // ts, frameID, fragIndex, fragCount, flags, puis au moins 1 octet de données.
            let fixed = 8 + 4 + 2 + 2 + 1
            return (fixed + 1)...(fixed + Limits.maxFragmentData)
        }
    }

    private func exactly(_ size: Int) -> ClosedRange<Int> { size...size }
}
