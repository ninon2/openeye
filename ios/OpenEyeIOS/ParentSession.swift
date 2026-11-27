import CryptoKit
import Foundation
import OpenEyeCore

/// Machine d'états de l'iPhone (docs/architecture.md §4) : appairage, visionnage, injoignable.
/// SecureChannel n'est utilisé que depuis le fil principal. Face ID s'exécute hors du fil principal.
@MainActor
final class ParentSession: ObservableObject {
    enum Phase: Equatable {
        case unpaired
        case scanning
        case pairing
        case confirmCode(String)
        case paired
        case connecting
        case authorizing
        case viewing
        case unreachable
    }

    @Published private(set) var phase: Phase
    @Published private(set) var status = ""
    @Published private(set) var macFingerprint: String?
    /// État de la capture annoncé par le Mac, quand il empêche de voir l'écran.
    @Published private(set) var captureNotice: String?
    /// Résultat de la vérification de l'ancre du journal, à lire par le parent.
    @Published private(set) var journalNotice: String?
    @Published private(set) var hasVideo = false
    /// Résultat de la dernière commande Verrouiller / Déverrouiller, à afficher au parent.
    @Published private(set) var commandNotice: String?
    /// Une commande est en cours : les boutons sont désactivés jusqu'au résultat.
    @Published private(set) var commandInFlight = false

    let renderer = VideoRenderer()

    private enum Mode {
        case idle
        case pairing
        case session
    }

    private let link = PhoneLink()
    private let clock = ContinuousClock()
    private var mode = Mode.idle
    /// Change à chaque tentative : un résultat asynchrone d'une ancienne tentative est ignoré.
    private var attempt = 0
    private var deadline: ContinuousClock.Instant?

    // Appairage
    private var pairing: ParentPairing?
    private var pendingAccept: Data?
    private var userConfirmedCode = false

    // Session
    private var macIdentity: P256.Signing.PublicKey?
    private var handshake: ParentHandshake?
    private var channel: SecureChannel?
    private var sessionReady = false
    private var lastAuthenticated: ContinuousClock.Instant
    private var lastKeepalive: ContinuousClock.Instant
    private var assembler = FrameAssembler()
    private var needsKeyFrame = true

    // Ancre du journal (docs/protocole.md §5)
    private var anchorBaseline: JournalAnchor?
    private var anchorRequestedAt: ContinuousClock.Instant?
    private var firstHeartbeatSeen = false
    private var verdict: AnchorVerdict?
    /// L'ancre n'est remplacée qu'après une vérification réussie, ou après lecture du message par le parent.
    private var mayReplaceAnchor = false

    // Commandes (docs/protocole.md §6)
    private enum CommandStep {
        case waitingForChallenge
        case signing
        case waitingForResult
    }
    private var command: (kind: CommandKind, seconds: UInt32, step: CommandStep)?
    private var commandDeadline: ContinuousClock.Instant?

    private var ticker: Task<Void, Never>?

    init() {
        macIdentity = MacStore.load()
        let hasKey = ParentSigner.load() != nil
        phase = macIdentity != nil && hasKey ? .paired : .unpaired
        macFingerprint = macIdentity?.shortFingerprint
        lastAuthenticated = clock.now
        lastKeepalive = clock.now
        if macIdentity != nil && !hasKey {
            // Visage ajouté ou clé perdue : la clé n'est plus utilisable, il faut réappairer.
            status = "La clé de cet iPhone n'est plus disponible : appairez à nouveau le Mac."
            MacStore.delete()
            AnchorStore.delete()
            macIdentity = nil
            macFingerprint = nil
        }

        link.onConnected = { [weak self] in self?.connected() }
        link.onDisconnected = { [weak self] in self?.disconnected() }
        link.onData = { [weak self] in self?.receive($0) }
        link.onBrowsingFailed = { [weak self] in
            self?.fail("Recherche impossible : autorisez l'accès au réseau local dans Réglages.")
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    // MARK: - Appairage

    func startScanning() {
        guard phase == .unpaired else { return }
        status = ""
        phase = .scanning
    }

    func cancelScanning() {
        guard phase == .scanning else { return }
        phase = .unpaired
    }

    /// Le QR est une donnée hostile : il est validé avant toute connexion.
    func scanned(_ text: String) {
        guard phase == .scanning else { return }
        let qr: QRPayload
        do {
            qr = try QRPayload(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                               now: UInt64(Date().timeIntervalSince1970))
        } catch PairingError.expired {
            return fail("QR expiré : affichez un nouveau QR sur le Mac.", to: .unpaired)
        } catch {
            return fail("Ce QR n'est pas un QR d'appairage OpenEye valide.", to: .unpaired)
        }
        do {
            let signer = try ParentSigner.create().withReason("Confirmer l'appairage avec le Mac")
            pairing = ParentPairing(parent: signer, qr: qr)
        } catch {
            return fail("Impossible de créer la clé dans la Secure Enclave (Face ID configuré ?).", to: .unpaired)
        }
        attempt += 1
        mode = .pairing
        pendingAccept = nil
        userConfirmedCode = false
        phase = .pairing
        status = "Connexion au Mac…"
        deadline = clock.now.advanced(by: .seconds(20))
        link.connect()
    }

    /// Le parent a comparé les 6 chiffres sur les deux écrans.
    func confirmCode(_ match: Bool) {
        guard case .confirmCode = phase, let pairing else { return }
        guard match else {
            _ = try? pairing.finish(accept: Data(), codesMatch: false)
            return fail("Codes différents : appairage abandonné.", to: .unpaired)
        }
        userConfirmedCode = true
        if let accept = pendingAccept {
            finishPairing(accept)
        } else {
            status = "Code confirmé. Confirmez aussi sur le Mac…"
            deadline = clock.now.advanced(by: .seconds(Int64(Limits.pairingLifetimeSeconds)))
        }
    }

    private func receivePairing(_ packet: Data) {
        guard packet.count >= Limits.headerSize, let pairing else { return }
        switch FrameType(rawValue: packet[packet.startIndex + 3]) {
        case .pairNonce:
            status = "Face ID…"
            deadline = nil
            let current = attempt
            Task {
                // Face ID bloque : hors du fil principal.
                let result = await Task.detached { Result { try pairing.reveal(nonce: packet) } }.value
                guard current == attempt else { return }
                switch result {
                case let .success((reveal, code)):
                    link.send(reveal)
                    phase = .confirmCode(code)
                    status = "Comparez ce code avec celui affiché sur le Mac."
                    deadline = clock.now.advanced(by: .seconds(Int64(Limits.pairingLifetimeSeconds)))
                case .failure:
                    fail("Appairage annulé (Face ID refusé ou message invalide).", to: .unpaired)
                }
            }
        case .pairAccept:
            if userConfirmedCode {
                finishPairing(packet)
            } else {
                // Vérifié seulement au clic du parent, dans finishPairing : rien n'est enregistré avant.
                pendingAccept = packet
                status = "Le Mac a confirmé. Vérifiez le code, puis confirmez ici."
            }
        case .reject:
            fail("Le Mac a refusé l'appairage.", to: .unpaired)
        default:
            fail("Message inattendu : appairage abandonné.", to: .unpaired)
        }
    }

    private func finishPairing(_ accept: Data) {
        guard let pairing else { return }
        do {
            // La signature du Mac porte sur NOTRE clé : un intrus appairé à notre place est détecté ici.
            let mac = try pairing.finish(accept: accept, codesMatch: true)
            try MacStore.save(mac)
            AnchorStore.delete()
            macIdentity = mac
            macFingerprint = mac.shortFingerprint
            self.pairing = nil
            mode = .idle
            deadline = nil
            link.disconnect()
            phase = .paired
            status = "Mac appairé."
        } catch {
            fail("Signature du Mac invalide : appairage refusé.", to: .unpaired)
        }
    }

    /// « Oublier ce Mac » : clé du Mac, clé Secure Enclave de cet appairage et ancre supprimées.
    func forgetMac() {
        stopViewing(reason: .userStop)
        MacStore.delete()
        ParentSigner.delete()
        AnchorStore.delete()
        macIdentity = nil
        macFingerprint = nil
        journalNotice = nil
        phase = .unpaired
        status = "Mac oublié."
    }

    // MARK: - Visionnage

    /// Chaque visionnage repart d'un handshake complet : nouvelles clés, nouveau Face ID.
    func startViewing() {
        guard phase == .paired || phase == .unreachable else { return }
        guard let mac = macIdentity,
              let signer = ParentSigner.load()?.withReason("Autoriser le visionnage de l'écran du Mac")
        else { return fail("Clé introuvable : appairez à nouveau le Mac.", to: .unpaired) }
        resetSession()
        attempt += 1
        mode = .session
        handshake = ParentHandshake(parent: signer, macIdentity: mac)
        phase = .connecting
        status = "Recherche du Mac…"
        deadline = clock.now.advanced(by: .seconds(20))
        link.connect()
    }

    /// Bouton Arrêter ou passage en arrière-plan : Close, puis clés effacées des deux côtés.
    func stopViewing(reason: CloseReason) {
        guard mode == .session else { return }
        seal(.close, payload: CloseMessage(reason: reason).payload)
        let link = link
        // Laisse partir le Close avant de couper.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { link.disconnect() }
        resetSession()
        mode = .idle
        phase = macIdentity == nil ? .unpaired : .paired
        status = reason == .background ? "Visionnage fermé (app en arrière-plan)." : "Visionnage arrêté."
    }

    func acknowledgeJournalNotice() {
        journalNotice = nil
        mayReplaceAnchor = true
    }

    private func receiveSession(_ packet: Data) {
        guard let channel else { return receiveHandshake(packet) }
        var allowed: Set<FrameType> = sessionReady ? [.heartbeat, .videoParams, .videoFragment, .close] : [.sessionReady, .close]
        if anchorRequestedAt != nil { allowed.insert(.journalAnchorProof) }
        // Un défi ou un résultat non demandé est un type inattendu : rejeté et compté.
        switch command?.step {
        case .waitingForChallenge: allowed.formUnion([.cmdChallenge, .cmdResult])
        case .waitingForResult: allowed.insert(.cmdResult)
        case .signing, nil: break
        }
        let message: SecureMessage
        do {
            message = try channel.open(packet, allowed: allowed, wallClock: wallClockMilliseconds(), now: clock.now)
        } catch {
            if channel.isClosed { endSession("Session fermée : trop de paquets invalides.") }
            return
        }
        lastAuthenticated = clock.now
        if phase == .unreachable && sessionReady {
            // Un message authentifié rétablit l'état.
            phase = .viewing
            status = ""
        }
        switch message.type {
        case .sessionReady:
            sessionReady = true
            deadline = nil
            phase = .viewing
            status = ""
            sendKeepalive()
            requestAnchorProof()
        case .heartbeat:
            if let heartbeat = try? Heartbeat(payload: message.payload) { handle(heartbeat) }
        case .videoParams:
            if let params = try? VideoParams(payload: message.payload) { renderer.configure(params) }
        case .videoFragment:
            handleFragment(message.payload)
        case .journalAnchorProof:
            handleAnchorProof(message.payload)
        case .cmdChallenge:
            handleCommandChallenge(message.payload)
        case .cmdResult:
            handleCommandResult(message.payload)
        case .close:
            let reason = (try? CloseMessage(payload: message.payload).reason) ?? .error
            endSession(Self.describe(reason))
        default:
            break
        }
    }

    private func receiveHandshake(_ packet: Data) {
        guard packet.count >= Limits.headerSize, let handshake else { return }
        switch FrameType(rawValue: packet[packet.startIndex + 3]) {
        case .challenge:
            phase = .authorizing
            status = "Face ID…"
            deadline = nil
            let current = attempt
            let now = { ContinuousClock().now }
            Task {
                // Le Mac est vérifié AVANT Face ID : un faux Mac n'obtient jamais de demande Face ID.
                let result = await Task.detached { Result { try handshake.answer(challenge: packet, now: now) } }.value
                guard current == attempt, mode == .session else { return }
                switch result {
                case let .success((auth, channel)):
                    self.handshake = nil
                    self.channel = channel
                    lastAuthenticated = clock.now
                    link.send(auth)
                    status = "Ouverture du flux…"
                    deadline = clock.now.advanced(by: .seconds(10))
                case let .failure(error):
                    let message = error is HandshakeError
                        ? "Ce Mac n'est pas celui qui a été appairé : visionnage refusé."
                        : "Face ID annulé : aucun flux ouvert."
                    fail(message, to: .paired)
                }
            }
        case .reject:
            fail("Le Mac a refusé le visionnage.", to: .paired)
        default:
            fail("Message inattendu : visionnage abandonné.", to: .paired)
        }
    }

    private func handleFragment(_ payload: Data) {
        do {
            guard let frame = try assembler.add(payload, now: clock.now) else { return }
            if needsKeyFrame && !frame.isKeyFrame { return }
            needsKeyFrame = !renderer.display(frame)
            if !hasVideo && !needsKeyFrame { hasVideo = true }
        } catch {
            needsKeyFrame = true
        }
    }

    private func handle(_ heartbeat: Heartbeat) {
        switch heartbeat.captureState {
        case .running: captureNotice = nil
        case .stopped: captureNotice = hasVideo ? "Capture arrêtée sur le Mac." : "Démarrage de la capture sur le Mac…"
        case .permissionDenied: captureNotice = "Autorisation de capture refusée sur le Mac."
        case .indicatorUnavailable: captureNotice = "L'indicateur du Mac est indisponible : aucune capture."
        }

        if !firstHeartbeatSeen {
            firstHeartbeatSeen = true
            if let anchor = anchorBaseline, AnchorCheck.headIsBehind(anchor: anchor, heartbeat: heartbeat) {
                apply(.altered)
            }
        }
        // Ancre : la plus haute tête vue, datée par l'horloge de l'iPhone.
        guard mayReplaceAnchor, heartbeat.journalSeq > 0 else { return }
        if heartbeat.journalSeq > (AnchorStore.load()?.seq ?? 0) {
            AnchorStore.save(JournalAnchor(
                seq: heartbeat.journalSeq, hash: heartbeat.journalHead, receivedAt: wallClockMilliseconds()
            ))
        }
    }

    private func requestAnchorProof() {
        guard let anchor = AnchorStore.load() else {
            mayReplaceAnchor = true
            return
        }
        anchorBaseline = anchor
        anchorRequestedAt = clock.now
        seal(.journalAnchorRequest, payload: JournalAnchorRequest(seq: anchor.seq).payload)
    }

    private func handleAnchorProof(_ payload: Data) {
        guard let anchor = anchorBaseline, let proof = try? JournalAnchorProof(payload: payload),
              proof.seq == anchor.seq
        else { return }
        anchorRequestedAt = nil
        apply(AnchorCheck.evaluate(anchor: anchor, proof: proof, now: wallClockMilliseconds()))
    }

    /// Le pire verdict l'emporte : une alerte n'est jamais effacée par une réponse rassurante.
    private func apply(_ newVerdict: AnchorVerdict) {
        if verdict == .altered { return }
        verdict = newVerdict
        switch newVerdict {
        case .consistent, .purgedNormally:
            mayReplaceAnchor = journalNotice == nil
        case .altered:
            mayReplaceAnchor = false
            journalNotice = "Journal du Mac altéré : des entrées ont été supprimées ou modifiées."
        case .impossibleClockChanged:
            mayReplaceAnchor = false
            journalNotice = "Vérification du journal impossible : horloge de l'iPhone modifiée."
        case .impossibleNoAnswer:
            mayReplaceAnchor = false
            journalNotice = "Vérification du journal impossible : pas de réponse du Mac."
        }
    }

    // MARK: - Commandes Verrouiller / Déverrouiller (docs/protocole.md §6)

    /// Demande un défi neuf au Mac. Face ID vient ensuite, sur ce défi : jamais de signature réutilisée (L8).
    func send(_ kind: CommandKind, minutes: UInt32 = 0) {
        guard phase == .viewing, sessionReady, command == nil else { return }
        command = (kind, minutes * 60, .waitingForChallenge)
        commandInFlight = true
        commandNotice = nil
        commandDeadline = clock.now.advanced(by: Limits.commandChallengeLifetime)
        seal(.cmdChallengeRequest)
    }

    private func handleCommandChallenge(_ payload: Data) {
        guard let pending = command, let channel,
              let challenge = try? CommandChallenge(payload: payload)
        else { return finishCommand("Défi invalide : aucune commande envoyée.") }
        let reason = pending.kind == .lock
            ? "Verrouiller l'écran du Mac pendant \(pending.seconds / 60) min"
            : "Déverrouiller l'écran du Mac"
        guard let signer = ParentSigner.load()?.withReason(reason) else {
            return finishCommand("Clé introuvable : aucune commande envoyée.")
        }
        command?.step = .signing
        let sessionID = channel.sessionID
        let current = attempt
        Task {
            // Face ID bloque : hors du fil principal.
            let result = await Task.detached {
                Result {
                    try SignedCommand.make(
                        pending.kind, durationSeconds: pending.seconds, challenge: challenge,
                        sessionID: sessionID, signer: signer
                    )
                }
            }.value
            guard current == attempt, mode == .session, command != nil else { return }
            switch result {
            case let .success(signed):
                command?.step = .waitingForResult
                commandDeadline = clock.now.advanced(by: .seconds(10))
                seal(pending.kind.frameType, payload: signed.payload)
            case .failure:
                finishCommand("Face ID annulé : aucune commande envoyée.")
            }
        }
    }

    private func handleCommandResult(_ payload: Data) {
        guard let result = try? CommandResult(payload: payload) else {
            return finishCommand("Réponse du Mac illisible.")
        }
        switch result.status {
        case .locked:
            let end = Date(timeIntervalSince1970: TimeInterval(result.endsAt) / 1_000)
            finishCommand("Écran du Mac verrouillé jusqu'à \(end.formatted(date: .omitted, time: .shortened)).")
        case .unlocked:
            finishCommand("Écran du Mac déverrouillé.")
        case .refused:
            finishCommand("Le Mac a refusé la commande.")
        }
    }

    private func finishCommand(_ message: String?) {
        command = nil
        commandDeadline = nil
        commandInFlight = false
        commandNotice = message
    }

    // MARK: - Connexion

    private func connected() {
        switch mode {
        case .pairing:
            guard let pairing else { return }
            do {
                link.send(try pairing.makeRequest())
                status = "Demande envoyée au Mac…"
                deadline = clock.now.advanced(by: .seconds(15))
            } catch {
                fail("Appairage impossible.", to: .unpaired)
            }
        case .session:
            guard let handshake else { return }
            do {
                link.send(try handshake.makeHello())
                status = "Vérification du Mac…"
                deadline = clock.now.advanced(by: .seconds(10))
            } catch {
                fail("Visionnage impossible.", to: .paired)
            }
        case .idle:
            link.disconnect()
        }
    }

    private func disconnected() {
        switch mode {
        case .pairing:
            // PairAccept déjà reçu : la signature du Mac suffit, la connexion n'est plus utile.
            // Il reste la décision du parent, bornée par `deadline`. Sans PairAccept, l'appairage échoue.
            if pairing != nil, pendingAccept == nil {
                fail("Connexion au Mac perdue pendant l'appairage.", to: .unpaired)
            }
        case .session:
            if sessionReady {
                // Perte de contact : causes multiples possibles, on ne conclut rien de plus.
                channel?.close()
                channel = nil
                renderer.clear()
                hasVideo = false
                phase = .unreachable
                status = "Mac injoignable : perte de contact (Mac fermé, hors de portée ou réseau coupé)."
                mode = .idle
            } else {
                fail("Connexion au Mac perdue.", to: .paired)
            }
        case .idle:
            break
        }
    }

    private func receive(_ packet: Data) {
        switch mode {
        case .pairing: receivePairing(packet)
        case .session: receiveSession(packet)
        case .idle: break
        }
    }

    // MARK: - Minuteries

    private func tick() {
        let now = clock.now
        if let deadline, now >= deadline {
            self.deadline = nil
            switch mode {
            case .pairing: fail("Le Mac ne répond pas : appairage abandonné.", to: .unpaired)
            case .session: fail("Le Mac ne répond pas.", to: .paired)
            case .idle: break
            }
        }
        guard mode == .session, sessionReady, channel != nil else { return }
        assembler.purge(now: now)
        if lastKeepalive.duration(to: now) >= Limits.heartbeatPeriod { sendKeepalive() }
        if phase == .viewing, lastAuthenticated.duration(to: now) >= Limits.unreachableAfter {
            phase = .unreachable
            status = "Mac injoignable : aucun signe depuis 6 s (plusieurs causes possibles)."
        }
        if let requested = anchorRequestedAt, requested.duration(to: now) >= Limits.anchorReplyTimeout {
            anchorRequestedAt = nil
            apply(.impossibleNoAnswer)
        }
        // Pendant Face ID, on attend le parent : c'est le Mac qui refusera un défi périmé.
        if let commandDeadline, now >= commandDeadline, command?.step != .signing {
            finishCommand("Pas de réponse du Mac : commande abandonnée.")
        }
    }

    private func sendKeepalive() {
        lastKeepalive = clock.now
        seal(.keepalive)
    }

    private func seal(_ type: FrameType, payload: Data = Data()) {
        guard let channel, !channel.isClosed else { return }
        do {
            link.send(try channel.seal(type, payload: payload, timestamp: wallClockMilliseconds(), now: clock.now))
        } catch ChannelError.sessionExpired {
            endSession("Session de 60 min terminée : relancez le visionnage (Face ID).")
        } catch {
            endSession("Erreur : visionnage fermé.")
        }
    }

    // MARK: - Fin

    private func endSession(_ message: String) {
        link.disconnect()
        resetSession()
        mode = .idle
        phase = macIdentity == nil ? .unpaired : .paired
        status = message
    }

    private func fail(_ message: String, to phase: Phase? = nil) {
        if mode == .pairing {
            // Une clé créée pour un appairage raté ne sert à rien.
            if macIdentity == nil { ParentSigner.delete() }
            pairing = nil
        }
        link.disconnect()
        resetSession()
        mode = .idle
        deadline = nil
        self.phase = phase ?? (macIdentity == nil ? .unpaired : .paired)
        status = message
    }

    /// Clés oubliées, files vidées, dernière image effacée.
    private func resetSession() {
        attempt += 1
        channel?.close()
        channel = nil
        handshake = nil
        sessionReady = false
        assembler.reset()
        needsKeyFrame = true
        renderer.clear()
        hasVideo = false
        captureNotice = nil
        anchorBaseline = nil
        anchorRequestedAt = nil
        firstHeartbeatSeen = false
        verdict = nil
        mayReplaceAnchor = false
        command = nil
        commandDeadline = nil
        commandInFlight = false
    }

    private static func describe(_ reason: CloseReason) -> String {
        switch reason {
        case .userStop: return "Le partage a été arrêté sur le Mac."
        case .background, .error: return "Le Mac a fermé la session."
        case .keepaliveLost: return "Le Mac n'a plus reçu de signe de l'iPhone."
        case .permissionDenied: return "Autorisation de capture refusée sur le Mac."
        case .indicatorUnavailable: return "L'indicateur du Mac est indisponible : aucune capture."
        case .sessionExpired: return "Session de 60 min terminée : relancez le visionnage (Face ID)."
        case .tooManyFailures: return "Session fermée : trop de paquets invalides."
        case .transportLost: return "Connexion perdue."
        }
    }
}
