import CryptoKit
import Foundation

/// Calculs communs aux deux appareils (docs/protocole.md §2.2).
enum PairingMath {
    /// Engagement : fige P_pub et nI avant de connaître nM.
    static func commitment(parentIdentity: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("OpenEye/v1/commit".utf8) + parentIdentity + nonce))
    }

    /// K_mac : clé dérivée du secret du QR. Le secret lui-même ne sert jamais directement.
    static func macKey(secret: SymmetricKey, pairingID: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secret, salt: pairingID,
            info: Data("OpenEye/v1/pair-mac".utf8), outputByteCount: 32
        )
    }

    /// Octets couverts par le HMAC : libellé, en-tête du paquet, puis champs préfixés.
    static func requestMessage(pairingID: Data, parentIdentity: Data, commitment: Data) throws -> Data {
        let header = try FrameHeader(type: .pairRequest, sessionID: 0, counter: 0, bodyLength: 145)
        return Data("OpenEye/v1/pair-request".utf8) + header.encoded
            + Transcript.lengthPrefixed(pairingID)
            + Transcript.lengthPrefixed(parentIdentity)
            + Transcript.lengthPrefixed(commitment)
    }

    /// TP : hash de tout l'appairage.
    static func transcript(
        pairingID: Data, macIdentity: Data, parentIdentity: Data, iPhoneNonce: Data, macNonce: Data
    ) -> Data {
        var bytes = Data("OpenEye/v1/pair-transcript".utf8)
        for field in [pairingID, macIdentity, parentIdentity, iPhoneNonce, macNonce] {
            bytes += Transcript.lengthPrefixed(field)
        }
        return Data(SHA256.hash(data: bytes))
    }

    /// Code à 6 chiffres comparé par l'humain sur les deux écrans.
    static func code(transcript: Data) -> String {
        let digest = SHA256.hash(data: Data("OpenEye/v1/sas".utf8) + transcript)
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let digits = String(number)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    static func parentMessage(_ transcript: Data) -> Data { Data("OpenEye/v1/pair".utf8) + transcript }
    static func macMessage(_ transcript: Data) -> Data { Data("OpenEye/v1/pair-accept".utf8) + transcript }

    static func packet(_ type: FrameType, body: Data) throws -> Data {
        let header = try FrameHeader(type: type, sessionID: 0, counter: 0, bodyLength: body.count)
        return try FrameCodec.encode(header: header, body: body)
    }

    static func verify(_ signature: Data, of message: Data, with key: P256.Signing.PublicKey) throws {
        guard let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              key.isValidSignature(parsed, for: message)
        else { throw PairingError.invalidSignature }
    }
}

/// Côté iPhone. Un objet = une tentative.
public final class ParentPairing {
    private enum State {
        case ready
        case waitingForNonce(nonce: Data)
        case waitingForAccept(transcript: Data)
        case finished
    }

    private let parent: any Signer
    private let qr: QRPayload
    private var state = State.ready

    public init(parent: any Signer, qr: QRPayload) {
        self.parent = parent
        self.qr = qr
    }

    /// PairRequest { pairingID, P_pub, C, hmac } : nI reste secret à cette étape.
    public func makeRequest() throws -> Data {
        guard case .ready = state else { throw fail(.invalidState) }
        state = .finished
        let identity = parent.publicKey.x963Representation
        let nonce = Transcript.randomNonce()
        let commitment = PairingMath.commitment(parentIdentity: identity, nonce: nonce)
        let message = try PairingMath.requestMessage(
            pairingID: qr.pairingID, parentIdentity: identity, commitment: commitment
        )
        let mac = HMAC<SHA256>.authenticationCode(
            for: message, using: PairingMath.macKey(secret: qr.secret, pairingID: qr.pairingID)
        )
        let packet = try PairingMath.packet(
            .pairRequest, body: qr.pairingID + identity + commitment + Data(mac)
        )
        state = .waitingForNonce(nonce: nonce)
        return packet
    }

    /// Reçoit PairNonce, demande Face ID, révèle nI. Renvoie aussi le code à afficher.
    public func reveal(nonce packet: Data) throws -> (reveal: Data, code: String) {
        guard case let .waitingForNonce(nonce) = state else { throw fail(.invalidState) }
        state = .finished
        let body = try FrameCodec.decode(packet, from: .mac, allowed: [.pairNonce]).body
        guard Data(body.prefix(16)) == qr.pairingID else { throw PairingError.wrongPairing }

        let transcript = PairingMath.transcript(
            pairingID: qr.pairingID, macIdentity: qr.macIdentity.x963Representation,
            parentIdentity: parent.publicKey.x963Representation,
            iPhoneNonce: nonce, macNonce: Data(body.suffix(32))
        )
        let signature = try parent.sign(PairingMath.parentMessage(transcript))
        let reveal = try PairingMath.packet(.pairReveal, body: qr.pairingID + nonce + signature)
        state = .waitingForAccept(transcript: transcript)
        return (reveal, PairingMath.code(transcript: transcript))
    }

    /// Renvoie la clé du Mac à enregistrer, seulement si l'humain ET la signature sont d'accord.
    public func finish(accept packet: Data, codesMatch: Bool) throws -> P256.Signing.PublicKey {
        guard case let .waitingForAccept(transcript) = state else { throw fail(.invalidState) }
        state = .finished
        guard codesMatch else { throw PairingError.refusedByUser }
        let body = try FrameCodec.decode(packet, from: .mac, allowed: [.pairAccept]).body
        guard Data(body.prefix(16)) == qr.pairingID else { throw PairingError.wrongPairing }
        // Le Mac signe NOTRE P_pub : un intrus appairé à notre place est détecté ici.
        try PairingMath.verify(
            Data(body.suffix(64)), of: PairingMath.macMessage(transcript), with: qr.macIdentity
        )
        return qr.macIdentity
    }

    private func fail(_ error: PairingError) -> PairingError {
        state = .finished
        return error
    }
}

/// Côté Mac. Un objet = un QR = une tentative.
public final class MacPairing {
    private enum State {
        case waitingForRequest(QRPayload)
        case waitingForReveal(pairingID: Data, parent: P256.Signing.PublicKey, commitment: Data, nonce: Data)
        case waitingForUser(pairingID: Data, parent: P256.Signing.PublicKey, transcript: Data)
        case finished
    }

    private let mac: any Signer
    private let createdAt: ContinuousClock.Instant
    private var state: State
    /// Texte du QR à afficher. Vaut nil dès qu'une demande est arrivée : le secret est alors oublié.
    public var qrText: String? {
        if case let .waitingForRequest(qr) = state { return qr.text }
        return nil
    }

    /// - Parameter wallClock: secondes Unix, pour la date d'expiration lue par l'iPhone.
    public init(mac: any Signer, wallClock: UInt64, now: ContinuousClock.Instant) {
        let payload = QRPayload(
            pairingID: Data(Transcript.randomNonce().prefix(16)),
            secret: SymmetricKey(size: .bits256),
            expiry: wallClock + Limits.pairingLifetimeSeconds,
            macIdentity: mac.publicKey
        )
        self.mac = mac
        self.createdAt = now
        self.state = .waitingForRequest(payload)
    }

    /// Reçoit PairRequest, renvoie PairNonce. Tout écart brûle le QR.
    public func makeNonce(request packet: Data, now: ContinuousClock.Instant) throws -> Data {
        guard case let .waitingForRequest(qr) = state else { throw fail(.invalidState) }
        state = .finished
        try checkLifetime(now)

        let body = try FrameCodec.decode(packet, from: .iphone, allowed: [.pairRequest]).body
        let pairingID = Data(body.prefix(16))
        let identity = Data(body.dropFirst(16).prefix(65))
        let commitment = Data(body.dropFirst(81).prefix(32))
        let mac = Data(body.suffix(32))

        guard pairingID == qr.pairingID else { throw PairingError.wrongPairing }
        let message = try PairingMath.requestMessage(
            pairingID: pairingID, parentIdentity: identity, commitment: commitment
        )
        // Comparaison à temps constant : seul quelqu'un qui a vu le QR connaît la clé.
        guard HMAC<SHA256>.isValidAuthenticationCode(
            mac, authenticating: message,
            using: PairingMath.macKey(secret: qr.secret, pairingID: pairingID)
        ) else { throw PairingError.invalidMAC }
        guard let parent = try? P256.Signing.PublicKey(x963Representation: identity) else {
            throw PairingError.invalidKey
        }

        let nonce = Transcript.randomNonce()
        let reply = try PairingMath.packet(.pairNonce, body: pairingID + nonce)
        state = .waitingForReveal(pairingID: pairingID, parent: parent, commitment: commitment, nonce: nonce)
        return reply
    }

    /// Reçoit PairReveal, renvoie le code à afficher.
    public func verify(reveal packet: Data, now: ContinuousClock.Instant) throws -> String {
        guard case let .waitingForReveal(pairingID, parent, commitment, macNonce) = state else {
            throw fail(.invalidState)
        }
        state = .finished
        try checkLifetime(now)

        let body = try FrameCodec.decode(packet, from: .iphone, allowed: [.pairReveal]).body
        guard Data(body.prefix(16)) == pairingID else { throw PairingError.wrongPairing }
        let iPhoneNonce = Data(body.dropFirst(16).prefix(32))
        let identity = parent.x963Representation

        // Le nonce révélé doit être celui promis avant l'envoi de nM.
        guard PairingMath.commitment(parentIdentity: identity, nonce: iPhoneNonce) == commitment else {
            throw PairingError.invalidCommitment
        }
        let transcript = PairingMath.transcript(
            pairingID: pairingID, macIdentity: mac.publicKey.x963Representation,
            parentIdentity: identity, iPhoneNonce: iPhoneNonce, macNonce: macNonce
        )
        // Preuve que l'iPhone détient la clé, Face ID compris.
        try PairingMath.verify(
            Data(body.suffix(64)), of: PairingMath.parentMessage(transcript), with: parent
        )
        state = .waitingForUser(pairingID: pairingID, parent: parent, transcript: transcript)
        return PairingMath.code(transcript: transcript)
    }

    /// Après le clic humain. Renvoie PairAccept et la clé du parent à enregistrer.
    public func confirm(
        codesMatch: Bool, now: ContinuousClock.Instant
    ) throws -> (accept: Data, parentIdentity: P256.Signing.PublicKey) {
        guard case let .waitingForUser(pairingID, parent, transcript) = state else { throw fail(.invalidState) }
        state = .finished
        guard codesMatch else { throw PairingError.refusedByUser }
        try checkLifetime(now)
        let signature = try mac.sign(PairingMath.macMessage(transcript))
        return (try PairingMath.packet(.pairAccept, body: pairingID + signature), parent)
    }

    /// Le QR vaut 120 s : une fois expiré, toute la tentative échoue.
    private func checkLifetime(_ now: ContinuousClock.Instant) throws {
        guard createdAt.duration(to: now) < .seconds(Int64(Limits.pairingLifetimeSeconds)) else {
            throw PairingError.expired
        }
    }

    private func fail(_ error: PairingError) -> PairingError {
        state = .finished
        return error
    }
}
