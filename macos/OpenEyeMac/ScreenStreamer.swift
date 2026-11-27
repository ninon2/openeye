import AVFoundation
import CoreImage
import CoreMedia
import CoreText
import Foundation
import OpenEyeCore
import ScreenCaptureKit
import VideoToolbox

/// Image H.264 encodée (format AVCC, longueurs de NAL sur 4 octets). Vit en mémoire, jamais sur disque.
struct EncodedFrame {
    let data: Data
    let isKeyFrame: Bool
    /// Présents sur chaque image clé : VideoParams est envoyé juste avant elle.
    let params: VideoParams?
}

enum CaptureError: Error {
    case noDisplay
    case encoder(OSStatus)
}

/// Capture de l'écran principal, sans audio ni webcam, puis encodage H.264 matériel
/// (docs/architecture.md §7). Ne conserve aucune image : chacune est livrée puis libérée.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "openeye.capture")
    private let onFrame: (EncodedFrame) -> Void
    private let onSystemStop: (Error) -> Void
    private var stream: SCStream?
    // Les variables suivantes ne sont lues et écrites que sur `queue`.
    private var encoder: VTCompressionSession?
    private var forceKeyFrame = false
    private var width = 0
    private var height = 0
    /// File d'envoi bornée (STRIDE D3) : images livrées mais pas encore envoyées. Protégée par `gate`.
    private let gate = NSLock()
    private var inFlight = 0
    private var skipUntilKeyFrame = false
    /// Caméra incrustée en vignette, seulement pendant une activation demandée par le parent. Sur `queue`.
    private var cameraFeed: CameraFeed?
    private var compositor: VignetteCompositor?
    #if DEBUG
    private let usesTestPattern: Bool
    /// Minuterie de la mire, sur `queue`.
    private var patternTimer: DispatchSourceTimer?
    #endif

    /// Les deux rappels sont appelés hors du fil principal.
    /// `testPattern` n'existe qu'en Debug : un build Release capture toujours l'écran.
    #if DEBUG
    init(testPattern: Bool = false, onFrame: @escaping (EncodedFrame) -> Void, onSystemStop: @escaping (Error) -> Void) {
        self.usesTestPattern = testPattern
        self.onFrame = onFrame
        self.onSystemStop = onSystemStop
    }
    #else
    init(onFrame: @escaping (EncodedFrame) -> Void, onSystemStop: @escaping (Error) -> Void) {
        self.onFrame = onFrame
        self.onSystemStop = onSystemStop
    }
    #endif

    func start() async throws {
        #if DEBUG
        if usesTestPattern { return try startTestPattern() }
        #endif
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
        // Minimisation : jamais d'audio ni de micro.
        configuration.capturesAudio = false

        let newEncoder = try Self.makeEncoder(width: Int32(width), height: Int32(height))
        queue.sync {
            encoder = newEncoder
            self.width = width
            self.height = height
        }

        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration, delegate: self
        )
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            self.stream = nil
            releaseEncoder()
            throw error
        }
    }

    /// Arrête la capture. Une erreur signifie que l'arrêt n'est pas confirmé.
    func stop() async throws {
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                // Déjà arrêtée par le système : c'est bien un arrêt.
                let nsError = error as NSError
                guard nsError.domain == SCStreamErrorDomain,
                      nsError.code == SCStreamError.attemptToStopStreamState.rawValue
                else { throw error }
            }
        }
        stream = nil
        // La caméra ne survit jamais à la capture : fin de session = caméra éteinte.
        queue.sync {
            cameraFeed?.stop()
            cameraFeed = nil
            compositor = nil
        }
        #if DEBUG
        // La minuterie s'arrête AVANT la libération de l'encodeur : plus aucune image après stop().
        queue.sync {
            patternTimer?.cancel()
            patternTimer = nil
        }
        #endif
        releaseEncoder()
    }

    /// À appeler sur le fil principal après avoir traité chaque image livrée.
    func frameHandled() {
        gate.lock()
        inFlight = max(0, inFlight - 1)
        gate.unlock()
    }

    /// Au-delà de 3 images en attente, on jette jusqu'à la prochaine image clé (docs/architecture.md §7).
    private func admit(isKeyFrame: Bool) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        if skipUntilKeyFrame && !isKeyFrame { return false }
        guard inFlight < Limits.maxQueuedFrames else {
            skipUntilKeyFrame = true
            requestKeyFrame()
            return false
        }
        skipUntilKeyFrame = false
        inFlight += 1
        return true
    }

    /// Branche ou retire la caméra. L'ancienne source est arrêtée ici : jamais deux caméras ouvertes.
    func setCamera(_ feed: CameraFeed?) {
        queue.async {
            self.cameraFeed?.stop()
            self.cameraFeed = feed
            if feed == nil { self.compositor = nil }
            // L'iPhone voit le changement immédiatement, sans attendre la prochaine image clé.
            self.forceKeyFrame = true
        }
    }

    /// Retire la caméra et attend que ce soit fait : au retour, plus aucune image ne la contient.
    func removeCamera() {
        queue.sync {
            cameraFeed?.stop()
            cameraFeed = nil
            compositor = nil
            forceKeyFrame = true
        }
    }

    /// La prochaine image sera une image clé, après une image jetée.
    func requestKeyFrame() {
        queue.async { self.forceKeyFrame = true }
    }

    private func releaseEncoder() {
        queue.sync {
            if let encoder {
                VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(encoder)
            }
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
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
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

    // MARK: - SCStreamOutput (sur `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.isComplete(sampleBuffer), let image = sampleBuffer.imageBuffer else { return }
        encode(image, at: sampleBuffer.presentationTimeStamp)
    }

    /// Encodage commun à l'écran et à la mire (Debug) : le chemin H.264 est strictement le même. Sur `queue`.
    private func encode(_ captured: CVImageBuffer, at time: CMTime) {
        guard let encoder else { return }
        // Caméra active : vignette en bas à droite, dans la même image. Sans image caméra, l'écran seul part.
        var image = captured
        if let frame = cameraFeed?.latestFrame() {
            if compositor == nil { compositor = VignetteCompositor(width: width, height: height) }
            image = compositor?.compose(screen: captured, camera: frame) ?? captured
        }
        var properties: CFDictionary?
        if forceKeyFrame {
            forceKeyFrame = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        let (width, height) = (self.width, self.height)
        VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: image, presentationTimeStamp: time,
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { status, _, encoded in
            guard status == noErr, let encoded, let data = Self.bytes(of: encoded) else { return }
            let isKeyFrame = Self.isKeyFrame(encoded)
            let params = isKeyFrame ? Self.parameterSets(of: encoded, width: width, height: height) : nil
            // Une image clé sans paramètres serait indécodable : on la saute.
            if isKeyFrame && params == nil { return }
            guard self.admit(isKeyFrame: isKeyFrame) else { return }
            self.onFrame(EncodedFrame(data: data, isKeyFrame: isKeyFrame, params: params))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onSystemStop(error)
    }

    // MARK: - Aides

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

    private static func bytes(of buffer: CMSampleBuffer) -> Data? {
        guard let block = buffer.dataBuffer else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    private static func parameterSets(of buffer: CMSampleBuffer, width: Int, height: Int) -> VideoParams? {
        guard let format = buffer.formatDescription else { return nil }
        var sets: [Data] = []
        for index in 0..<2 { // 0 : SPS, 1 : PPS
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return try? VideoParams(width: width, height: height, sps: sets[0], pps: sets[1])
    }
}

#if DEBUG
// MARK: - Mire de test (Debug uniquement, absente des builds Release)

/// Remplace la capture quand macOS la refuse (Mac sans droits administrateur).
/// L'écran n'est jamais lu : l'image est dessinée ici, puis suit exactement le même encodage.
/// Le texte « MIRE DE TEST » est incrusté dans l'image : le parent ne peut pas la prendre pour l'écran.
extension ScreenStreamer {
    static let testPatternWidth = 960
    static let testPatternHeight = 600

    fileprivate func startTestPattern() throws {
        let (width, height) = (Self.testPatternWidth, Self.testPatternHeight)
        let newEncoder = try Self.makeEncoder(width: Int32(width), height: Int32(height))
        queue.sync {
            encoder = newEncoder
            self.width = width
            self.height = height
            var index = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // 10 images par seconde, comme la capture d'écran.
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                index += 1
                guard let self,
                      let image = Self.testPatternImage(width: width, height: height, frame: index, date: Date())
                else { return }
                self.encode(image, at: CMTime(value: CMTimeValue(index), timescale: 10))
            }
            patternTimer = timer
            timer.resume()
        }
    }

    /// Barres de couleur, carré mobile (le flux est vivant) et heure à la milliseconde (mesure de latence).
    static func testPatternImage(width: Int, height: Int, frame: Int, date: Date) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let (w, h) = (CGFloat(width), CGFloat(height))
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1)]
        let barWidth = w / CGFloat(bars.count)
        for (index, color) in bars.enumerated() {
            context.setFillColor(red: color.0 * 0.75, green: color.1 * 0.75, blue: color.2 * 0.75, alpha: 1)
            context.fill(CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth + 1, height: h))
        }

        let side: CGFloat = 60
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: CGFloat(frame * 8).truncatingRemainder(dividingBy: w - side), y: 40, width: side, height: side))

        context.setFillColor(gray: 0, alpha: 0.85)
        context.fill(CGRect(x: 0, y: h - 200, width: w, height: 160))
        let time = date.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
                .secondFraction(.fractional(3))
        )
        drawText("MIRE DE TEST — ce n'est pas l'écran du Mac", size: 34, at: CGPoint(x: 30, y: h - 90), in: context)
        drawText("\(time)   ·   image n° \(frame)", size: 30, at: CGPoint(x: 30, y: h - 150), in: context)
        return buffer
    }

    fileprivate static func drawText(_ text: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Menlo-Bold" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }
}
#endif

// MARK: - Caméra (extension webcam, désactivée par défaut)

/// Source d'images caméra lue par l'encodeur : seule la DERNIÈRE image est gardée, en mémoire.
protocol CameraFeed: AnyObject, Sendable {
    func latestFrame() -> CVPixelBuffer?
    func stop()
}

/// Webcam du Mac, ouverte seulement pendant une activation signée par le parent.
/// 640 × 480 au plus (minimisation), sans micro, rien n'est enregistré. macOS allume aussi son voyant vert.
final class CameraSource: NSObject, CameraFeed, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "openeye.camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    /// Ouvre la caméra si macOS l'autorise et si un appareil existe, sinon nil. Bloquant : hors du fil principal.
    static func start() -> CameraSource? {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return nil }
        let source = CameraSource()
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(source, queue: source.queue)

        source.session.beginConfiguration()
        if source.session.canSetSessionPreset(.vga640x480) { source.session.sessionPreset = .vga640x480 }
        guard source.session.canAddInput(input), source.session.canAddOutput(output) else {
            source.session.commitConfiguration()
            return nil
        }
        source.session.addInput(input)
        source.session.addOutput(output)
        source.session.commitConfiguration()
        source.session.startRunning()
        return source.session.isRunning ? source : nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = sampleBuffer.imageBuffer else { return }
        lock.lock()
        latest = image
        lock.unlock()
    }

    func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func stop() {
        session.stopRunning()
        lock.lock()
        latest = nil
        lock.unlock()
    }
}

/// Incruste la caméra en vignette (30 % de la largeur, bas droit, cadre blanc) dans l'image envoyée.
/// Une seule image H.264 : le protocole vidéo ne change pas. Utilisé sur la file de capture uniquement.
final class VignetteCompositor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let width: Int
    private let height: Int
    private var pool: CVPixelBufferPool?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }

    func compose(screen: CVImageBuffer, camera: CVImageBuffer) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let output = buffer
        else { return nil }

        let base = CIImage(cvImageBuffer: screen)
        let cam = CIImage(cvImageBuffer: camera)
        let scale = CGFloat(width) * 0.3 / max(cam.extent.width, 1)
        let scaled = cam.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let margin: CGFloat = 12
        let placed = scaled.transformed(by: CGAffineTransform(
            translationX: CGFloat(width) - scaled.extent.width - margin - scaled.extent.minX,
            y: margin - scaled.extent.minY
        ))
        let frame = CIImage(color: .white).cropped(to: placed.extent.insetBy(dx: -3, dy: -3))
        context.render(placed.composited(over: frame.composited(over: base)), to: output)
        return output
    }
}

#if DEBUG
/// Remplace la caméra quand macOS en refuse l'accès (Debug uniquement) : vignette générée, explicite.
final class CameraTestPattern: CameraFeed, @unchecked Sendable {
    private let lock = NSLock()
    private var frame = 0

    func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        frame += 1
        let index = frame
        lock.unlock()
        return ScreenStreamer.cameraPatternImage(frame: index, date: Date())
    }

    func stop() {}
}

extension ScreenStreamer {
    /// 320 × 240 : fond sombre, « MIRE CAMÉRA », raison et heure. Aucune image réelle.
    static func cameraPatternImage(frame: Int, date: Date) -> CVPixelBuffer? {
        let (width, height) = (320, 240)
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(red: 0.15, green: 0.15, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: CGFloat(frame * 4 % (width - 30)), y: 20, width: 30, height: 30))
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        drawText("MIRE CAMÉRA", size: 26, at: CGPoint(x: 16, y: 180), in: context)
        drawText("accès caméra refusé", size: 18, at: CGPoint(x: 16, y: 140), in: context)
        drawText(time, size: 18, at: CGPoint(x: 16, y: 100), in: context)
        return buffer
    }
}
#endif
