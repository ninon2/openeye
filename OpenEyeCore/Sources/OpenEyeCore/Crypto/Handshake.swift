import CryptoKit
import Foundation

public enum HandshakeError: Error, Equatable, Sendable {
    /// Objet déjà utilisé, étape dans le désordre, ou échec précédent.
    case invalidState
    case unknownParent
    case invalidKey
    case invalidSignature
    case challengeExpired
}

/// Côté iPhone. Un objet = une tentative : après une erreur, il faut en créer un autre.
public final class ParentHandshake {
    private enum State {
        case ready
        case waitingForChallenge(ephemeral: P256.KeyAgreement.PrivateKey, nonce: Data)
        case finished
    }

    private let parent: any Signer
    private let macIdentity: P256.Signing.PublicKey
    private var state = State.ready

    /// `macIdentity` : la clé enregistrée à l'appairage, jamais une clé reçue du réseau.
    public init(parent: any Signer, macIdentity: P256.Signing.PublicKey) {
        self.parent = parent
        self.macIdentity = macIdentity
    }

    /// Hello { fpP, eI_pub, nI }
    public func makeHello() throws -> Data {
        guard case .ready = state else {
            state = .finished
            throw HandshakeError.invalidState
        }
        state = .finished
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let nonce = Transcript.randomNonce()
        let body = Data(SHA256.hash(data: parent.publicKey.x963Representation))
            + ephemeral.publicKey.x963Representation + nonce
        let packet = try clearPacket(.hello, body: body)
        state = .waitingForChallenge(ephemeral: ephemeral, nonce: nonce)
        return packet
    }

    /// Vérifie le Mac, PUIS demande Face ID. Renvoie le paquet Auth et le canal ouvert.
    public func answer(
        challenge packet: Data, now: () -> ContinuousClock.Instant
    ) throws -> (auth: Data, channel: SecureChannel) {
        guard case let .waitingForChallenge(ephemeral, nonce) = state else {
            state = .finished
            throw HandshakeError.invalidState
        }
        // Dès ici, la moindre erreur laisse l'objet inutilisable et la clé éphémère oubliée.
        state = .finished

        let body = try FrameCodec.decode(packet, from: .mac, allowed: [.challenge]).body
        let macEphemeralBytes = Data(body.prefix(65))
        let macNonce = Data(body.dropFirst(65).prefix(32))
        let macSignature = Data(body.suffix(64))

        let macEphemeral = try ephemeralKey(macEphemeralBytes)
        let transcript = Transcript.session(
            macIdentity: macIdentity.x963Representation,
            parentIdentity: parent.publicKey.x963Representation,
            iPhoneEphemeral: ephemeral.publicKey.x963Representation, iPhoneNonce: nonce,
            macEphemeral: macEphemeralBytes, macNonce: macNonce
        )
        // S2 : c'est bien le Mac appairé. Face ID n'est pas demandé à un faux Mac.
        try verify(
            macSignature, of: Transcript.labeled(Transcript.macSignatureLabel, transcript), with: macIdentity
        )

        // Face ID et Secure Enclave. Annulation = erreur = aucun paquet Auth.
        let signature = try parent.sign(Transcript.labeled(Transcript.parentSignatureLabel, transcript))
        let auth = try clearPacket(.auth, body: signature)
        let keys = try SessionKeys.derive(
            ephemeral: ephemeral, peerEphemeral: macEphemeral, transcriptHash: transcript
        )
        return (auth, SecureChannel(localRole: .iphone, keys: keys, openedAt: now()))
    }
}

/// Côté Mac. Un objet = une tentative.
public final class MacHandshake {
    private struct Pending {
        let ephemeral: P256.KeyAgreement.PrivateKey
        let peerEphemeral: P256.KeyAgreement.PublicKey
        let transcript: Data
        let sentAt: ContinuousClock.Instant
    }

    private enum State {
        case ready
        case waitingForAuth(Pending)
        case finished
    }

    /// Résultat d'un handshake réussi. Transcript et signature servent de preuve au journal (R1).
    public struct Session {
        public let channel: SecureChannel
        public let transcriptHash: Data
        public let parentSignature: Data
    }

    private let mac: any Signer
    private let parentIdentity: P256.Signing.PublicKey
    private var state = State.ready

    /// `parentIdentity` : la clé enregistrée à l'appairage.
    public init(mac: any Signer, parentIdentity: P256.Signing.PublicKey) {
        self.mac = mac
        self.parentIdentity = parentIdentity
    }

    /// Reçoit Hello, renvoie Challenge { eM_pub, nM, sigM }.
    public func makeChallenge(hello packet: Data, now: ContinuousClock.Instant) throws -> Data {
        guard case .ready = state else {
            state = .finished
            throw HandshakeError.invalidState
        }
        state = .finished

        let body = try FrameCodec.decode(packet, from: .iphone, allowed: [.hello]).body
        let fingerprint = Data(body.prefix(32))
        let iPhoneEphemeralBytes = Data(body.dropFirst(32).prefix(65))
        let iPhoneNonce = Data(body.suffix(32))

        // Empreinte publique : ce n'est pas un secret, une comparaison ordinaire suffit.
        guard fingerprint == Data(SHA256.hash(data: parentIdentity.x963Representation)) else {
            throw HandshakeError.unknownParent
        }
        let iPhoneEphemeral = try ephemeralKey(iPhoneEphemeralBytes)

        let ephemeral = P256.KeyAgreement.PrivateKey()
        let nonce = Transcript.randomNonce()
        let transcript = Transcript.session(
            macIdentity: mac.publicKey.x963Representation,
            parentIdentity: parentIdentity.x963Representation,
            iPhoneEphemeral: iPhoneEphemeralBytes, iPhoneNonce: iPhoneNonce,
            macEphemeral: ephemeral.publicKey.x963Representation, macNonce: nonce
        )
        let signature = try mac.sign(Transcript.labeled(Transcript.macSignatureLabel, transcript))
        let challenge = try clearPacket(
            .challenge, body: ephemeral.publicKey.x963Representation + nonce + signature
        )
        state = .waitingForAuth(Pending(
            ephemeral: ephemeral, peerEphemeral: iPhoneEphemeral, transcript: transcript, sentAt: now
        ))
        return challenge
    }

    /// Reçoit Auth. L'appelant affiche l'indicateur PUIS démarre la capture, jamais avant ce retour.
    public func accept(auth packet: Data, now: ContinuousClock.Instant) throws -> Session {
        guard case let .waitingForAuth(pending) = state else {
            state = .finished
            throw HandshakeError.invalidState
        }
        // E2 : le défi est consommé, que la réponse soit bonne ou non.
        state = .finished

        guard pending.sentAt.duration(to: now) < Limits.challengeLifetime else {
            throw HandshakeError.challengeExpired
        }
        let signature = try FrameCodec.decode(packet, from: .iphone, allowed: [.auth]).body
        try verify(
            signature,
            of: Transcript.labeled(Transcript.parentSignatureLabel, pending.transcript),
            with: parentIdentity
        )
        let keys = try SessionKeys.derive(
            ephemeral: pending.ephemeral, peerEphemeral: pending.peerEphemeral,
            transcriptHash: pending.transcript
        )
        return Session(
            channel: SecureChannel(localRole: .mac, keys: keys, openedAt: now),
            transcriptHash: pending.transcript,
            parentSignature: signature
        )
    }
}

// MARK: - Aides communes

private func clearPacket(_ type: FrameType, body: Data) throws -> Data {
    let header = try FrameHeader(type: type, sessionID: 0, counter: 0, bodyLength: body.count)
    return try FrameCodec.encode(header: header, body: body)
}

/// CryptoKit refuse ici un point qui n'est pas sur la courbe.
private func ephemeralKey(_ bytes: Data) throws -> P256.KeyAgreement.PublicKey {
    do {
        return try P256.KeyAgreement.PublicKey(x963Representation: bytes)
    } catch {
        throw HandshakeError.invalidKey
    }
}

private func verify(_ signature: Data, of message: Data, with key: P256.Signing.PublicKey) throws {
    guard let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
          key.isValidSignature(parsed, for: message)
    else { throw HandshakeError.invalidSignature }
}
