import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import OpenEyeCore

/// Machine d'états du Mac (docs/architecture.md §4) : appairage, handshake, diffusion, arrêt.
/// Tout l'état de session vit sur le fil principal : SecureChannel n'est utilisé que d'ici.
@MainActor
final class MacSession: ObservableObject {
    enum Phase: Equatable {
        case waiting
        case pairing
        case handshake
        case streaming
        case stopping
    }

    @Published private(set) var phase = Phase.waiting
    @Published private(set) var parent: P256.Signing.PublicKey?
    @Published private(set) var status = "En attente"
    @Published private(set) var qrText: String?
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingDeadline: Date?
    @Published private(set) var isCapturing = false
    @Published private(set) var isConnected = false
    @Published private(set) var framesSent = 0
    /// Fin du verrouillage en cours. Il survit à la session : couper la connexion ne débloque pas (L5).
    @Published private(set) var lockedUntil: Date?
    #if DEBUG
    /// Vrai pendant un visionnage qui envoie la mire, faute d'autorisation de capture (Debug uniquement).
    @Published private(set) var sendsTestPattern = false
    #endif
    /// Caméra montrée au parent en vignette, pendant tout le visionnage. Ne survit jamais à la session.
    @Published private(set) var cameraActive = false
    /// Vrai si la vignette caméra est une mire (accès caméra refusé, Debug uniquement).
    @Published private(set) var cameraIsTestPattern = false

    let signer: MacSigner
    let journal: JournalStore

    private let link = MacLink()
    private let indicator = Indicator()
    private let lockScreen = LockScreen()
    private let clock = ContinuousClock()
    /// Défis des commandes, propres à la session en cours.
    private var commands = CommandGate()

    private var pairing: MacPairing?
    private var pairingExpiresAt: ContinuousClock.Instant?
    private var handshake: MacHandshake?
    private var channel: SecureChannel?
    private var sessionID: UInt64?
    private var streamer: ScreenStreamer?
    private var startTask: Task<Void, Never>?
    private var splitter = FrameSplitter()
    private var captureState = CaptureState.stopped
    private var waitingForKeyFrame = false
    private var anchorRequestAllowed = false
    private var lastKeepalive: ContinuousClock.Instant
    private var lastHeartbeat: ContinuousClock.Instant
    /// Délai du Hello après connexion, puis de l'Auth après le Challenge (STRIDE D2, E2).
    private var connectionDeadline: ContinuousClock.Instant?
    private var isEnding = false
    private var ticker: Task<Void, Never>?

    init(signer: MacSigner) {
        self.signer = signer
        self.journal = JournalStore(signer: signer)
        self.parent = ParentStore.load()
        self.lastKeepalive = clock.now
        self.lastHeartbeat = clock.now

        link.onConnected = { [weak self] in self?.connected() }
        link.onDisconnected = { [weak self] in self?.disconnected() }
        link.onData = { [weak self] in self?.receive($0) }
        link.onAdvertisingFailed = { [weak self] in
            self?.status = "Annonce impossible : vérifiez l'accès au réseau local"
        }

        journal.append(.appStarted)
        link.start()
        status = parent == nil ? "Aucun iPhone appairé" : "Prêt : en attente de l'iPhone du parent"
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    var macFingerprint: String { signer.publicKey.shortFingerprint }

    // MARK: - Actions de l'interface

    /// Affiche un QR à usage unique, valable 120 s.
    func startPairing() {
        guard phase == .waiting else { return }
        let now = clock.now
        let pairing = MacPairing(mac: signer, wallClock: UInt64(Date().timeIntervalSince1970), now: now)
        self.pairing = pairing
        pairingExpiresAt = now.advanced(by: .seconds(Int64(Limits.pairingLifetimeSeconds)))
        pairingDeadline = Date().addingTimeInterval(TimeInterval(Limits.pairingLifetimeSeconds))
        qrText = pairing.qrText
        pairingCode = nil
        phase = .pairing
        status = "Scannez le QR avec l'app OpenEye de l'iPhone"
    }

    func cancelPairing() {
        abortPairing("Appairage annulé")
        link.disconnect()
    }

    /// Le parent a comparé les 6 chiffres sur les deux écrans.
    func confirmPairing(codesMatch: Bool) {
        guard let pairing else { return }
        do {
            let (accept, key) = try pairing.confirm(codesMatch: codesMatch, now: clock.now)
            link.send(accept)
            try ParentStore.save(key)
            parent = key
            journal.append(.paired, data: JournalData.paired(parent: key))
            finishPairing(status: "iPhone appairé (\(key.shortFingerprint))")
        } catch PairingError.refusedByUser {
            sendReject()
            finishPairing(status: "Codes différents : appairage refusé")
        } catch {
            sendReject()
            finishPairing(status: "Appairage échoué : recommencez avec un nouveau QR")
        }
        // Laisse partir le dernier message avant de couper.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if self.channel == nil && self.handshake == nil { self.link.disconnect() }
        }
    }

    /// « Révoquer l'iPhone » : la clé du parent est supprimée, il faudra réappairer.
    func revoke() async {
        if channel != nil { await end(.userStop, notifyPeer: true) }
        guard let parent else { return }
        ParentStore.delete()
        journal.append(.revoked, data: JournalData.revoked(parent: parent))
        self.parent = nil
        status = "iPhone révoqué : un nouvel appairage est nécessaire"
    }

    /// L'enfant peut toujours arrêter le partage : la supervision reste visible et consentie.
    func stopSharing() async {
        await end(.userStop, notifyPeer: true)
        status = "Partage arrêté sur ce Mac"
    }

    // MARK: - Connexion

    private func connected() {
        isConnected = true
        connectionDeadline = clock.now.advanced(by: Limits.helloTimeout)
    }

    private func disconnected() {
        isConnected = false
        connectionDeadline = nil
        handshake = nil
        if channel != nil || streamer != nil {
            Task { await end(.transportLost, notifyPeer: false) }
        } else if pairing != nil, qrText == nil {
            // Le QR a déjà été consommé : la tentative est perdue.
            abortPairing("Connexion perdue pendant l'appairage : recommencez")
        } else if phase == .handshake {
            phase = .waiting
            status = "Connexion perdue avant l'autorisation"
        }
    }

    private func receive(_ packet: Data) {
        if let channel {
            receiveInSession(packet, channel: channel)
            return
        }
        guard packet.count >= Limits.headerSize else { return sendReject() }
        switch FrameType(rawValue: packet[packet.startIndex + 3]) {
        case .pairRequest, .pairReveal: handlePairing(packet)
        case .hello: handleHello(packet)
        case .auth: handleAuth(packet)
        default: sendReject()
        }
    }

    // MARK: - Appairage

    private func handlePairing(_ packet: Data) {
        guard let pairing else { return sendReject() }
        let now = clock.now
        do {
            if packet[packet.startIndex + 3] == FrameType.pairRequest.rawValue {
                let reply = try pairing.makeNonce(request: packet, now: now)
                // Demande valide : 5 min pour Face ID et la comparaison, au lieu des 120 s du QR.
                pairingExpiresAt = pairing.deadline
                pairingDeadline = Date().addingTimeInterval(TimeInterval(now.duration(to: pairing.deadline).components.seconds))
                connectionDeadline = nil
                qrText = nil // Le secret est consommé : le QR disparaît.
                link.send(reply)
                status = "Demande reçue : Face ID sur l'iPhone…"
            } else {
                pairingCode = try pairing.verify(reveal: packet, now: now)
                status = "Comparez le code avec celui de l'iPhone"
            }
        } catch {
            sendReject()
            abortPairing("Appairage refusé : recommencez avec un nouveau QR")
        }
    }

    private func abortPairing(_ message: String) {
        guard pairing != nil else { return }
        finishPairing(status: message)
    }

    private func finishPairing(status message: String) {
        pairing = nil
        pairingExpiresAt = nil
        pairingDeadline = nil
        qrText = nil
        pairingCode = nil
        phase = .waiting
        status = message
    }

    // MARK: - Handshake

    private func handleHello(_ packet: Data) {
        guard pairing == nil, handshake == nil, phase == .waiting, let parent else { return sendReject() }
        let handshake = MacHandshake(mac: signer, parentIdentity: parent)
        do {
            let challenge = try handshake.makeChallenge(hello: packet, now: clock.now)
            self.handshake = handshake
            connectionDeadline = clock.now.advanced(by: Limits.challengeLifetime)
            phase = .handshake
            status = "Autorisation Face ID demandée sur l'iPhone…"
            link.send(challenge)
        } catch {
            sendReject()
        }
    }

    private func handleAuth(_ packet: Data) {
        guard let handshake else { return sendReject() }
        self.handshake = nil
        do {
            open(try handshake.accept(auth: packet, now: clock.now))
        } catch {
            phase = .waiting
            status = "Autorisation refusée"
            sendReject()
        }
    }

    /// Auth valide : journal, puis indicateur, PUIS capture (docs/architecture.md §4, règle 1).
    private func open(_ session: MacHandshake.Session) {
        let channel = session.channel
        self.channel = channel
        sessionID = channel.sessionID
        connectionDeadline = nil
        lastKeepalive = clock.now
        anchorRequestAllowed = true
        commands = CommandGate()
        splitter = FrameSplitter()
        framesSent = 0
        phase = .streaming
        journal.append(.sessionOpened, data: JournalData.sessionOpened(
            sessionID: channel.sessionID, transcriptHash: session.transcriptHash,
            parentSignature: session.parentSignature
        ))
        seal(.sessionReady)

        // Autorisation accordée : TOUJOURS l'écran réel. Refusée : le refus est journalisé dans tous les cas.
        let screenAllowed = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        #if DEBUG
        // Debug : la mire prend le relais, sans rien lire à l'écran. Figée pour toute la session.
        if !screenAllowed { journal.append(.permissionDenied) }
        let testPattern = !screenAllowed
        sendsTestPattern = testPattern
        #else
        let testPattern = false
        #endif

        // Release : refus = échec sûr, rien n'est partagé.
        guard screenAllowed || testPattern else {
            journal.append(.permissionDenied)
            captureState = .permissionDenied
            sendHeartbeat()
            status = "Autorisation de capture refusée : rien n'est partagé"
            Task { await end(.permissionDenied, notifyPeer: true) }
            return
        }
        guard indicator.show() else {
            captureState = .indicatorUnavailable
            sendHeartbeat()
            status = "Indicateur impossible à afficher : rien n'est partagé"
            Task { await end(.indicatorUnavailable, notifyPeer: true) }
            return
        }

        // L'indicateur vient d'être affiché, AVANT la mire comme avant l'écran : même règle.
        let onFrame: (EncodedFrame) -> Void = { [weak self] frame in
            DispatchQueue.main.async { self?.send(frame) }
        }
        let onSystemStop: (Error) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.captureStoppedBySystem() }
        }
        #if DEBUG
        let streamer = ScreenStreamer(testPattern: testPattern, onFrame: onFrame, onSystemStop: onSystemStop)
        #else
        let streamer = ScreenStreamer(onFrame: onFrame, onSystemStop: onSystemStop)
        #endif
        self.streamer = streamer
        status = "Démarrage de la capture…"
        startTask = Task {
            do {
                try await streamer.start()
            } catch {
                // Un échec de la mire n'est pas un refus d'autorisation.
                captureState = testPattern || CGPreflightScreenCaptureAccess() ? .stopped : .permissionDenied
                if captureState == .permissionDenied { journal.append(.permissionDenied) }
                sendHeartbeat()
                startTask = nil
                status = "Capture impossible : rien n'est partagé"
                await end(captureState == .permissionDenied ? .permissionDenied : .error, notifyPeer: true)
                return
            }
            startTask = nil
            captureState = .running
            isCapturing = true
            journal.append(.captureStarted, data: JournalData.capture(sessionID: channel.sessionID))
            // Écran ET caméra pendant tout le visionnage : qui est devant le Mac, et ce qu'il fait.
            // Tâche séparée : un arrêt n'attend jamais la réponse à la demande d'accès caméra.
            Task { await startCamera() }
            status = testPattern ? "Mire de test partagée avec le parent (votre écran n'est pas envoyé)"
                : "Écran partagé avec le parent"
            sendHeartbeat()
        }
    }

    // MARK: - Session établie

    private func receiveInSession(_ packet: Data, channel: SecureChannel) {
        var allowed: Set<FrameType> = [.keepalive, .close, .cmdChallengeRequest, .lock, .unlock]
        if anchorRequestAllowed { allowed.insert(.journalAnchorRequest) }
        do {
            let message = try channel.open(packet, allowed: allowed, wallClock: wallClockMilliseconds(), now: clock.now)
            lastKeepalive = clock.now
            switch message.type {
            case .close:
                let reason = (try? CloseMessage(payload: message.payload).reason) ?? .error
                Task { await end(reason, notifyPeer: false) }
            case .journalAnchorRequest:
                // Une seule demande par session : la suivante sera un type inattendu.
                anchorRequestAllowed = false
                if let request = try? JournalAnchorRequest(payload: message.payload) {
                    seal(.journalAnchorProof, payload: journal.anchorProof(seq: request.seq).payload)
                }
            case .cmdChallengeRequest:
                issueCommandChallenge()
            case .lock:
                handleCommand(.lock, payload: message.payload)
            case .unlock:
                handleCommand(.unlock, payload: message.payload)
            default:
                break
            }
        } catch ChannelError.sessionExpired {
            Task { await end(.sessionExpired, notifyPeer: false) }
        } catch {
            // Au 20e rejet en 10 s, le canal s'est fermé : incident journalisé une seule fois.
            if channel.isClosed {
                journal.append(.authFailures, data: JournalData.authFailures(count: Limits.maxFailures))
                Task { await end(.tooManyFailures, notifyPeer: false) }
            }
        }
    }

    // MARK: - Commandes Verrouiller / Déverrouiller (docs/protocole.md §6)

    private func issueCommandChallenge() {
        do {
            seal(.cmdChallenge, payload: try commands.issueChallenge(now: clock.now).payload)
        } catch {
            // L6 : demande trop rapprochée de la précédente, sans effet.
            seal(.cmdResult, payload: CommandResult(status: .refused).payload)
        }
    }

    /// Signature du parent et défi vérifiés, PUIS journal, PUIS action (L1, L3, L7).
    private func handleCommand(_ kind: CommandKind, payload: Data) {
        guard let parent, let sessionID else { return }
        let command: SignedCommand
        let duration: UInt32
        do {
            command = try SignedCommand(kind, payload: payload)
            duration = try commands.accept(command, parent: parent, sessionID: sessionID, now: clock.now)
        } catch {
            status = "Commande refusée : signature ou défi invalide"
            seal(.cmdResult, payload: CommandResult(status: .refused).payload)
            return
        }
        journal.append(kind.journalEvent, data: JournalData.command(command, sessionID: sessionID))
        switch kind {
        case .lock:
            let endsAt = wallClockMilliseconds() + UInt64(duration) * 1_000
            let end = Date(timeIntervalSince1970: TimeInterval(endsAt) / 1_000)
            lockedUntil = end
            lockScreen.show(until: end)
            status = "Écran verrouillé par le parent"
            seal(.cmdResult, payload: CommandResult(status: .locked, endsAt: endsAt).payload)
        case .unlock:
            unlockScreen()
            status = "Écran déverrouillé par le parent"
            seal(.cmdResult, payload: CommandResult(status: .unlocked).payload)
        }
    }

    private func unlockScreen() {
        lockedUntil = nil
        lockScreen.hide()
    }

    // MARK: - Caméra (extension webcam)

    /// Autorisation macOS d'abord (l'enfant voit la demande), puis caméra réelle, en vignette.
    /// Refus : mire caméra en Debug, écran seul en Release. Rien n'est enregistré.
    private func startCamera() async {
        guard streamer != nil, !cameraActive else { return }
        // Bandeau mis à jour AVANT d'ouvrir la caméra : l'enfant est prévenu d'abord.
        indicator.setCamera(true)
        cameraActive = true
        var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        }
        var feed: CameraFeed? = allowed ? await Task.detached { CameraSource.start() }.value : nil
        #if DEBUG
        if feed == nil {
            feed = CameraTestPattern()
            cameraIsTestPattern = true
        }
        #endif
        // Visionnage terminé pendant l'attente, ou caméra indisponible (Release) : écran seul.
        guard let feed, cameraActive, let streamer else {
            feed?.stop()
            stopCamera()
            return
        }
        streamer.setCamera(feed)
    }

    /// Caméra coupée PUIS bandeau remis à « écran seul » : jamais de caméra sans bandeau qui l'annonce.
    private func stopCamera() {
        streamer?.removeCamera()
        cameraActive = false
        cameraIsTestPattern = false
        indicator.setCamera(false)
    }

    /// Image encodée : VideoParams avant chaque image clé, puis fragments chiffrés.
    private func send(_ frame: EncodedFrame) {
        defer { streamer?.frameHandled() }
        guard channel != nil, captureState == .running else { return }
        if waitingForKeyFrame && !frame.isKeyFrame { return }
        let fragments: [Data]
        do {
            fragments = try splitter.split(frame.data, isKeyFrame: frame.isKeyFrame)
        } catch {
            // Image trop grosse : on la jette et on attend la prochaine image clé.
            waitingForKeyFrame = true
            streamer?.requestKeyFrame()
            return
        }
        waitingForKeyFrame = false
        if let params = frame.params { seal(.videoParams, payload: params.payload) }
        for fragment in fragments { seal(.videoFragment, payload: fragment) }
        framesSent += 1
    }

    private func sendHeartbeat() {
        lastHeartbeat = clock.now
        let head = journal.head
        seal(.heartbeat, payload: Heartbeat(
            captureState: captureState, journalSeq: head.seq, journalHead: head.hash
        ).payload)
    }

    /// Chiffre et envoie. Une erreur ferme la session : jamais de reprise silencieuse avec les mêmes clés.
    private func seal(_ type: FrameType, payload: Data = Data()) {
        guard let channel, !channel.isClosed else { return }
        do {
            let packet = try channel.seal(type, payload: payload, timestamp: wallClockMilliseconds(), now: clock.now)
            guard link.send(packet) else { throw ChannelError.closed }
        } catch ChannelError.sessionExpired {
            Task { await end(.sessionExpired, notifyPeer: false) }
        } catch {
            Task { await end(.error, notifyPeer: false) }
        }
    }

    private func captureStoppedBySystem() {
        guard streamer != nil else { return }
        let denied = !CGPreflightScreenCaptureAccess()
        if denied {
            journal.append(.permissionDenied)
            captureState = .permissionDenied
            sendHeartbeat()
        }
        Task { await end(denied ? .permissionDenied : .error, notifyPeer: true) }
    }

    /// Arrêt : capture stoppée, PUIS indicateur masqué, clés effacées (docs/architecture.md §4, règles 2 et 3).
    private func end(_ reason: CloseReason, notifyPeer: Bool) async {
        guard !isEnding else { return }
        isEnding = true
        defer { isEnding = false }
        phase = .stopping
        // La caméra s'arrête en premier, quelle que soit la raison de la fin.
        stopCamera()

        if notifyPeer { seal(.close, payload: CloseMessage(reason: reason).payload) }
        // Un démarrage en cours se termine d'abord : sinon il pourrait capturer après l'arrêt.
        await startTask?.value
        if let streamer {
            do {
                try await streamer.stop()
            } catch {
                // Doute sur l'arrêt : l'indicateur RESTE visible.
                channel?.close()
                channel = nil
                link.disconnect()
                status = "Arrêt non confirmé : l'indicateur reste affiché, quittez l'app"
                return
            }
        }
        streamer = nil
        if isCapturing, let sessionID {
            journal.append(.captureStopped, data: JournalData.capture(sessionID: sessionID))
        }
        isCapturing = false
        #if DEBUG
        sendsTestPattern = false
        #endif
        captureState = .stopped
        indicator.hide()

        channel?.close()
        channel = nil
        if let sessionID {
            journal.append(.sessionClosed, data: JournalData.sessionClosed(sessionID: sessionID, reason: reason))
        }
        sessionID = nil
        handshake = nil
        waitingForKeyFrame = false
        splitter = FrameSplitter()
        if notifyPeer { try? await Task.sleep(for: .milliseconds(300)) }
        link.disconnect()
        phase = .waiting
        status = Self.describe(reason)
    }

    // MARK: - Minuteries

    private func tick() {
        let now = clock.now
        if let deadline = connectionDeadline, now >= deadline {
            // Hello ou Auth trop tardif : la connexion unique est libérée.
            connectionDeadline = nil
            handshake = nil
            if phase == .handshake { phase = .waiting; status = "Autorisation expirée" }
            link.disconnect()
        }
        if let expiry = pairingExpiresAt, now >= expiry {
            abortPairing("QR expiré : recommencez")
            link.disconnect()
        }
        // L5 : déverrouillage automatique à l'échéance, avec ou sans iPhone.
        if let lockedUntil, Date() >= lockedUntil {
            unlockScreen()
            status = "Fin du verrouillage"
        }
        guard channel != nil, !isEnding else { return }
        if lastKeepalive.duration(to: now) >= Limits.keepaliveTimeout {
            Task { await end(.keepaliveLost, notifyPeer: false) }
            return
        }
        if lastHeartbeat.duration(to: now) >= Limits.heartbeatPeriod { sendHeartbeat() }
    }

    private func sendReject() {
        if let header = try? FrameHeader(type: .reject, sessionID: 0, counter: 0, bodyLength: 1),
           let packet = try? FrameCodec.encode(header: header, body: Data([0])) {
            link.send(packet)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if self.channel == nil && self.pairing == nil { self.link.disconnect() }
        }
    }

    private static func describe(_ reason: CloseReason) -> String {
        switch reason {
        case .userStop: return "Partage arrêté"
        case .background: return "Le parent a quitté l'app : partage arrêté"
        case .keepaliveLost: return "iPhone injoignable : partage arrêté"
        case .permissionDenied: return "Autorisation de capture refusée : partage arrêté"
        case .indicatorUnavailable: return "Indicateur indisponible : partage arrêté"
        case .sessionExpired: return "Session de 60 min terminée : partage arrêté"
        case .tooManyFailures: return "Paquets invalides : session fermée"
        case .transportLost: return "Connexion perdue : partage arrêté"
        case .error: return "Erreur : partage arrêté"
        }
    }
}
