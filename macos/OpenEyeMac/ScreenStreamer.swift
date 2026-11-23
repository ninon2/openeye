import CoreMedia
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

    /// Les deux rappels sont appelés hors du fil principal.
    init(onFrame: @escaping (EncodedFrame) -> Void, onSystemStop: @escaping (Error) -> Void) {
        self.onFrame = onFrame
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
        guard type == .screen, let encoder, Self.isComplete(sampleBuffer),
              let image = sampleBuffer.imageBuffer
        else { return }
        var properties: CFDictionary?
        if forceKeyFrame {
            forceKeyFrame = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        let (width, height) = (self.width, self.height)
        VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: image, presentationTimeStamp: sampleBuffer.presentationTimeStamp,
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
