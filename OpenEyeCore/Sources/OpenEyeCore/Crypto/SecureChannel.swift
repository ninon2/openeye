import CryptoKit
import Foundation

public enum ChannelError: Error, Equatable, Sendable {
    case closed
    case sessionExpired
    case counterExhausted
    case wrongSession
    case badCounter
    case authenticationFailed
    case badTimestamp
}

/// Message authentifié, déchiffré et à jour.
public struct SecureMessage: Equatable, Sendable {
    public let type: FrameType
    /// Horodatage de l'émetteur, en millisecondes Unix.
    public let timestamp: UInt64
    /// Corps sans l'horodatage.
    public let payload: Data
}

/// Canal chiffré d'une session (docs/protocole.md §4). À utiliser depuis une seule file d'exécution.
public final class SecureChannel {
    public let sessionID: UInt64

    private let localRole: Sender
    private let openedAt: ContinuousClock.Instant
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var lastSent: UInt64
    private var lastAccepted: UInt64 = 0
    private var lastReceivedTimestamp: UInt64 = 0
    private var failures: [ContinuousClock.Instant] = []

    public var isClosed: Bool { sendKey == nil || receiveKey == nil }

    init(
        localRole: Sender, keys: SessionKeys, openedAt: ContinuousClock.Instant,
        lastSent: UInt64 = 0
    ) {
        self.localRole = localRole
        self.sessionID = keys.sessionID
        self.openedAt = openedAt
        self.sendKey = localRole == .mac ? keys.macToIPhone : keys.iPhoneToMac
        self.receiveKey = localRole == .mac ? keys.iPhoneToMac : keys.macToIPhone
        self.lastSent = lastSent
    }

    /// Oublie les clés : plus rien ne peut être chiffré ni déchiffré.
    public func close() {
        sendKey = nil
        receiveKey = nil
        failures = []
    }

    // MARK: - Émission

    public func seal(
        _ type: FrameType, payload: Data = Data(),
        timestamp: UInt64, now: ContinuousClock.Instant
    ) throws -> Data {
        let key = try activeKey(sendKey, now: now)
        guard type.isEncrypted else { throw FrameError.unexpectedType }
        guard type.canBeSent(by: localRole) else { throw FrameError.wrongDirection }

        let body = Data(FrameCodec.bigEndian(timestamp, byteCount: 8)) + payload
        let counter = lastSent + 1
        guard counter < Limits.counterLimit else {
            close()
            throw ChannelError.counterExhausted
        }
        let header = try FrameHeader(
            type: type, sessionID: sessionID, counter: counter, bodyLength: body.count
        )
        // Le compteur est consommé AVANT le chiffrement : même après une erreur, aucun nonce ne resservira.
        lastSent = counter

        let box = try AES.GCM.seal(
            body, using: key, nonce: Self.nonce(counter), authenticating: header.encoded
        )
        return try FrameCodec.encode(header: header, body: box.ciphertext, tag: box.tag)
    }

    // MARK: - Réception

    /// Étapes 1 à 9 (docs/protocole.md §4.4). Tout rejet est compté ; au 20e en 10 s, la session se ferme.
    public func open(
        _ packet: Data, allowed: Set<FrameType>,
        wallClock: UInt64, now: ContinuousClock.Instant
    ) throws -> SecureMessage {
        let key = try activeKey(receiveKey, now: now)
        do {
            return try decrypt(packet, key: key, allowed: allowed, wallClock: wallClock)
        } catch {
            registerFailure(now: now)
            throw error
        }
    }

    private func decrypt(
        _ packet: Data, key: SymmetricKey, allowed: Set<FrameType>, wallClock: UInt64
    ) throws -> SecureMessage {
        // Étapes 1 à 4 : forme du paquet.
        let peer: Sender = localRole == .mac ? .iphone : .mac
        let frame = try FrameCodec.decode(packet, from: peer, allowed: allowed)
        guard frame.header.type.isEncrypted else { throw FrameError.unexpectedType }

        // Étape 5 : bonne session.
        guard frame.header.sessionID == sessionID else { throw ChannelError.wrongSession }

        // Étape 6 : exactement le paquet suivant. Un rejeu ou un trou est refusé.
        guard frame.header.counter == lastAccepted + 1 else { throw ChannelError.badCounter }

        // Étape 7 : déchiffrement et authentification, en-tête compris (AAD).
        let body: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: Self.nonce(frame.header.counter), ciphertext: frame.body, tag: frame.tag
            )
            body = try AES.GCM.open(box, using: key, authenticating: frame.header.encoded)
        } catch {
            throw ChannelError.authenticationFailed
        }

        // Étape 8 : seulement maintenant, l'état avance.
        lastAccepted = frame.header.counter

        // Étape 9 : fraîcheur. Chaque corps chiffré commence par un horodatage (taille garantie par bodySize).
        let timestamp = body.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let gap = timestamp > wallClock ? timestamp - wallClock : wallClock - timestamp
        guard gap <= Limits.clockToleranceMilliseconds, timestamp >= lastReceivedTimestamp else {
            throw ChannelError.badTimestamp
        }
        lastReceivedTimestamp = timestamp
        return SecureMessage(
            type: frame.header.type, timestamp: timestamp, payload: Data(body.dropFirst(8))
        )
    }

    // MARK: - Aides

    private func activeKey(_ key: SymmetricKey?, now: ContinuousClock.Instant) throws -> SymmetricKey {
        guard let key else { throw ChannelError.closed }
        guard openedAt.duration(to: now) < Limits.maxSessionDuration else {
            close()
            throw ChannelError.sessionExpired
        }
        return key
    }

    private func registerFailure(now: ContinuousClock.Instant) {
        failures.removeAll { $0.duration(to: now) >= Limits.failureWindow }
        failures.append(now)
        if failures.count >= Limits.maxFailures { close() }
    }

    /// 4 octets nuls puis le compteur : unique par construction, car chaque sens a sa propre clé.
    private static func nonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data(count: 4) + Data(FrameCodec.bigEndian(counter, byteCount: 8)))
    }
}
