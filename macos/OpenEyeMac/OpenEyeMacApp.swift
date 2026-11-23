// PROTOTYPE JETABLE (tâches 14 et 15) : ne jamais fusionner dans main.
// But : vérifier l'autorisation de capture en session Guest, l'ordre indicateur/capture,
// et mesurer l'encodage H.264. Aucune image n'est enregistrée, envoyée ni affichée.

import AppKit
import CoreMedia
import MultipeerConnectivity
import ScreenCaptureKit
import SwiftUI
import VideoToolbox

@main
struct OpenEyeMacApp: App {
    @StateObject private var model = CaptureModel()
    @StateObject private var link = MacLink()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("OpenEye · prototype 14").font(.title)
                Text(model.status)
                Text(model.measures).font(.system(.body, design: .monospaced))
                HStack {
                    Button("Démarrer") { Task { await model.start() } }.disabled(model.isRunning)
                    Button("Arrêter") { Task { await model.stop(status: "Arrêté") } }.disabled(!model.isRunning)
                }
                Divider()
                Text("OpenEye · prototype 15").font(.title)
                Text(link.status)
                HStack {
                    Button(link.isAdvertising ? "Arrêter l'annonce" : "Annoncer") { link.toggle() }
                    ForEach([1, 4, 8], id: \.self) { rate in
                        Button("Envoyer \(rate) Mbit/s, 10 s") { link.sendBlocks(megabits: rate) }
                            .disabled(!link.isConnected || link.isSending)
                    }
                }
            }
            .padding()
            .frame(minWidth: 460, alignment: .leading)
        }
    }
}

@MainActor
final class CaptureModel: ObservableObject {
    @Published var status = "Arrêté"
    @Published var measures = ""
    @Published var isRunning = false

    private let indicator = Indicator()
    private var capture: ScreenCapture?

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        // 1. Autorisation. À la première demande, macOS peut exiger un mot de passe administrateur
        //    puis un redémarrage de l'app : c'est précisément ce que ce prototype doit constater.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            status = "Autorisation de capture refusée : rien n'a été capturé"
            isRunning = false
            return
        }
        // 2. L'indicateur AVANT la capture. S'il ne s'affiche pas, on ne capture pas.
        guard indicator.show() else {
            status = "Indicateur impossible à afficher : capture annulée"
            isRunning = false
            return
        }
        // 3. La capture.
        let capture = ScreenCapture { [weak self] in
            Task { @MainActor in await self?.stop(status: "Capture interrompue par le système") }
        }
        do {
            try await capture.start()
        } catch {
            await capture.abort()
            indicator.hide()
            status = "Démarrage impossible : rien n'est capturé"
            isRunning = false
            return
        }
        self.capture = capture
        status = "Capture en cours, indicateur visible"
        refreshMeasures(of: capture)
    }

    func stop(status newStatus: String) async {
        guard let capture else { return }
        do {
            try await capture.stop()
        } catch {
            // Doute sur l'arrêt : l'indicateur RESTE visible.
            status = "Arrêt non confirmé : l'indicateur reste affiché, quittez l'app"
            return
        }
        // La capture est arrêtée, PUIS l'indicateur disparaît.
        self.capture = nil
        indicator.hide()
        status = newStatus
        isRunning = false
    }

    private func refreshMeasures(of capture: ScreenCapture) {
        Task {
            let start = ContinuousClock().now
            while self.capture === capture {
                measures = capture.stats.summary(elapsed: start.duration(to: ContinuousClock().now))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Bandeau toujours au premier plan, sur tous les bureaux.
@MainActor
final class Indicator {
    private var panel: NSPanel?

    func show() -> Bool {
        guard let screen = NSScreen.main else { return false }
        let size = NSSize(width: 260, height: 32)
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: Text("● Écran partagé avec OpenEye")
            .foregroundStyle(.white).frame(width: size.width, height: size.height).background(.red))
        panel.orderFrontRegardless()
        self.panel = panel
        return panel.isVisible
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Mesures partagées entre la file de capture et l'interface.
final class CaptureStats: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, keyFrames = 0, bytes = 0
    private var largestFrame = 0, parameterSetBytes = 0, errors = 0

    func addFrame(size: Int, isKeyFrame: Bool, parameterSets: Int) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        bytes += size
        largestFrame = max(largestFrame, size)
        if isKeyFrame {
            keyFrames += 1
            parameterSetBytes = max(parameterSetBytes, parameterSets)
        }
    }

    func addError() {
        lock.lock(); defer { lock.unlock() }
        errors += 1
    }

    func summary(elapsed: Duration) -> String {
        lock.lock(); defer { lock.unlock() }
        let seconds = max(1, Double(elapsed.components.seconds))
        return """
        images        \(frames) (clés : \(keyFrames))
        cadence       \(String(format: "%.1f", Double(frames) / seconds)) images/s
        débit         \(Int(Double(bytes) * 8 / seconds / 1_000)) kbit/s
        plus grosse   \(largestFrame) octets
        SPS + PPS     \(parameterSetBytes) octets
        erreurs       \(errors)
        """
    }
}

enum CaptureError: Error {
    case noDisplay
    case encoder(OSStatus)
}

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let stats = CaptureStats()

    private let queue = DispatchQueue(label: "openeye.proto14.capture")
    private let onSystemStop: @Sendable () -> Void
    private var stream: SCStream?
    // Les deux variables suivantes ne sont lues et écrites que sur `queue`.
    private var encoder: VTCompressionSession?
    private var stoppedBySystem = false

    init(onSystemStop: @escaping @Sendable () -> Void) {
        self.onSystemStop = onSystemStop
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }),
              display.width > 0
        else { throw CaptureError.noDisplay }

        // 960 px de large, hauteur paire imposée par H.264.
        let width = 960
        let height = max(2, (width * display.height / display.width) & ~1)

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let newEncoder = try Self.makeEncoder(width: Int32(width), height: Int32(height))
        queue.sync { encoder = newEncoder }

        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration, delegate: self
        )
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stop() async throws {
        let alreadyStopped = queue.sync { stoppedBySystem }
        if !alreadyStopped { try await stream?.stopCapture() }
        stream = nil
        releaseEncoder()
    }

    /// Nettoyage après un démarrage raté.
    func abort() async {
        try? await stream?.stopCapture()
        stream = nil
        releaseEncoder()
    }

    private func releaseEncoder() {
        queue.sync {
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
        }
    }

    private static func makeEncoder(width: Int32, height: Int32) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw CaptureError.encoder(status) }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse), // pas d'images B
            (kVTCompressionPropertyKey_AverageBitRate, 1_000_000 as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 10 as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber),
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                VTCompressionSessionInvalidate(session)
                throw CaptureError.encoder(status)
            }
        }
        return session
    }

    // Appelé sur `queue`.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let encoder, Self.isComplete(sampleBuffer),
              let image = sampleBuffer.imageBuffer
        else { return }
        let stats = stats
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: image, presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { status, _, encoded in
            guard status == noErr, let encoded else {
                stats.addError()
                return
            }
            // On mesure la taille, puis l'image est libérée : rien n'est conservé.
            let isKeyFrame = Self.isKeyFrame(encoded)
            stats.addFrame(
                size: CMSampleBufferGetTotalSampleSize(encoded), isKeyFrame: isKeyFrame,
                parameterSets: isKeyFrame ? Self.parameterSetSize(encoded) : 0
            )
        }
        if status != noErr { stats.addError() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            stoppedBySystem = true
            onSystemStop()
        }
    }

    /// ScreenCaptureKit livre aussi des tampons sans nouvelle image : on les ignore.
    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        guard let raw = attachments?.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    private static func isKeyFrame(_ buffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[CFString: Any]]
        return !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static func parameterSetSize(_ buffer: CMSampleBuffer) -> Int {
        guard let format = buffer.formatDescription else { return 0 }
        var total = 0
        for index in 0..<2 { // 0 : SPS, 1 : PPS
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: nil,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if status == noErr { total += size }
        }
        return total
    }
}

// MARK: - Tâche 15

/// Liaison sans authentification : elle ne transporte que des octets synthétiques, jamais l'écran.
final class MacLink: NSObject, ObservableObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, @unchecked Sendable {
    @Published var status = "Arrêté"
    @Published var isAdvertising = false
    @Published var isConnected = false
    @Published var isSending = false

    // Jamais le nom de l'ordinateur : il contient souvent un prénom.
    private let peer = MCPeerID(displayName: "OpenEye-\(UUID().uuidString.prefix(4))")
    private lazy var session: MCSession = {
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }()
    private lazy var advertiser: MCNearbyServiceAdvertiser = {
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: "openeye")
        advertiser.delegate = self
        return advertiser
    }()

    func toggle() {
        if isAdvertising {
            advertiser.stopAdvertisingPeer()
            session.disconnect()
            isAdvertising = false
            status = "Arrêté"
        } else {
            advertiser.startAdvertisingPeer()
            isAdvertising = true
            status = "Annonce en cours"
        }
    }

    /// Blocs de 16 Kio à débit constant, pour ne pas remplir la file d'envoi de Multipeer.
    @MainActor
    func sendBlocks(megabits: Int) {
        guard !isSending else { return }
        isSending = true
        let blockSize = 16_384
        let count = megabits * 1_000_000 * 10 / 8 / blockSize
        Task { @MainActor in
            let clock = ContinuousClock()
            let start = clock.now
            var sent = 0
            for index in 0..<count {
                let due = start.advanced(by: .seconds(10) * index / count)
                try? await Task.sleep(until: due, clock: clock)
                let peers = session.connectedPeers
                guard !peers.isEmpty else { break }
                let id = UInt32(index).bigEndian
                let block = Data([3]) + withUnsafeBytes(of: id) { Data($0) } + Data(count: blockSize - 5)
                do {
                    try session.send(block, toPeers: peers, with: .reliable)
                    sent += 1
                } catch {
                    break
                }
            }
            status = "Envoyés : \(sent) blocs sur \(count)"
            isSending = false
        }
    }

    // MARK: Délégués

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Un seul appareil à la fois.
        let accept = session.connectedPeers.isEmpty
        invitationHandler(accept, accept ? session : nil)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.status = "Annonce refusée (réseau local ?)" }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.isConnected = !session.connectedPeers.isEmpty
            self.status = self.isConnected ? "Connecté" : "Non connecté"
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Seul message accepté : un ping de 9 octets, renvoyé en pong.
        guard data.count == 9, data.first == 1 else { return }
        try? session.send(Data([2]) + data.dropFirst(), toPeers: [peerID], with: .reliable)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
