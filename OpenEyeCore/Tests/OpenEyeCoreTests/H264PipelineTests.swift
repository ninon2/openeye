#if os(macOS)
import CoreMedia
import CryptoKit
import VideoToolbox
import XCTest
@testable import OpenEyeCore

/// Chaîne vidéo complète avec du VRAI H.264 (VideoToolbox), sans capture d'écran :
/// encodage → VideoParams + découpage → chiffrement → déchiffrement → réassemblage → décodage.
/// C'est ce que la mire de test (Debug) fait passer dans les apps. Images synthétiques, aucune vraie capture.
final class H264PipelineTests: XCTestCase {
    private let t0 = ContinuousClock().now
    private let wall: UInt64 = 1_700_000_000_000
    private let width = 320, height = 192

    // MARK: - Aides

    private struct Encoded {
        let data: Data
        let isKeyFrame: Bool
        let params: VideoParams?
    }

    private func channels() -> (mac: SecureChannel, iPhone: SecureChannel) {
        let keys = SessionKeys(
            macToIPhone: SymmetricKey(size: .bits256), iPhoneToMac: SymmetricKey(size: .bits256), sessionID: 42
        )
        return (
            SecureChannel(localRole: .mac, keys: keys, openedAt: t0),
            SecureChannel(localRole: .iphone, keys: keys, openedAt: t0)
        )
    }

    /// Image grise dont la teinte change à chaque index : le contenu bouge, comme la mire.
    private func pixelBuffer(_ index: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer),
            kCVReturnSuccess
        )
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
        memset(base, Int32(truncatingIfNeeded: index * 25), CVPixelBufferGetDataSize(pixels))
        return pixels
    }

    /// Mêmes réglages que ScreenStreamer : temps réel, pas d'images B, une image clé au moins toutes les 2 s.
    private func encode(frames count: Int) throws -> [Encoded] {
        var created: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created
        ), noErr)
        let session = try XCTUnwrap(created)
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        let lock = NSLock()
        var output: [Encoded] = []
        for index in 0..<count {
            VTCompressionSessionEncodeFrame(
                session, imageBuffer: try pixelBuffer(index),
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 10),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in
                guard status == noErr, let sample, let encoded = Self.encoded(sample, width: 320, height: 192) else { return }
                lock.lock()
                output.append(encoded)
                lock.unlock()
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    private static func encoded(_ sample: CMSampleBuffer, width: Int, height: Int) -> Encoded? {
        guard let block = sample.dataBuffer else { return nil }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var params: VideoParams?
        if isKeyFrame, let format = sample.formatDescription {
            var sets: [Data] = []
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                ) == noErr, let pointer else { return nil }
                sets.append(Data(bytes: pointer, count: size))
            }
            params = try? VideoParams(width: width, height: height, sps: sets[0], pps: sets[1])
        }
        return Encoded(data: data, isKeyFrame: isKeyFrame, params: params)
    }

    /// Côté iPhone : décode chaque image avec le format reconstruit à partir de VideoParams reçus.
    private func decode(_ frames: [VideoFrame], params: VideoParams) throws -> Int {
        let sps = [UInt8](params.sps), pps = [UInt8](params.pps)
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer -> OSStatus in
                guard let spsBase = spsBuffer.baseAddress, let ppsBase = ppsBuffer.baseAddress else { return -1 }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: [spsBase, ppsBase],
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format
                )
            }
        }
        XCTAssertEqual(status, noErr)
        let description = try XCTUnwrap(format)
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        XCTAssertEqual(Int(dimensions.width), width)
        XCTAssertEqual(Int(dimensions.height), height)

        var created: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(
            allocator: nil, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &created
        ), noErr)
        let session = try XCTUnwrap(created)
        defer { VTDecompressionSessionInvalidate(session) }

        let lock = NSLock()
        var decoded = 0
        for frame in frames {
            let sample = try sampleBuffer(frame.data, format: description)
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                guard status == noErr, image != nil else { return }
                lock.lock()
                decoded += 1
                lock.unlock()
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        lock.lock()
        defer { lock.unlock() }
        return decoded
    }

    private func sampleBuffer(_ data: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ), kCMBlockBufferNoErr)
        let buffer = try XCTUnwrap(block)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(with: base, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: raw.count)
        }
        var sample: CMSampleBuffer?
        var size = data.count
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: buffer, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample
        ), noErr)
        return try XCTUnwrap(sample)
    }

    /// Côté Mac, comme MacSession.send : VideoParams avant chaque image clé, puis fragments chiffrés.
    private func packets(for encoded: [Encoded], channel: SecureChannel) throws -> [Data] {
        var splitter = FrameSplitter()
        var packets: [Data] = []
        for frame in encoded {
            if let params = frame.params {
                packets.append(try channel.seal(.videoParams, payload: params.payload, timestamp: wall, now: t0))
            }
            for fragment in try splitter.split(frame.data, isKeyFrame: frame.isKeyFrame) {
                packets.append(try channel.seal(.videoFragment, payload: fragment, timestamp: wall, now: t0))
            }
        }
        return packets
    }

    private let allowed: Set<FrameType> = [.videoParams, .videoFragment]

    // MARK: - Cas normal

    func testRealH264SurvivesTheEncryptedPipelineAndDecodes() throws {
        let encoded = try encode(frames: 20)
        XCTAssertEqual(encoded.count, 20)
        XCTAssertTrue(try XCTUnwrap(encoded.first).isKeyFrame, "la première image doit être une image clé")

        let (mac, iPhone) = channels()
        var assembler = FrameAssembler()
        var params: VideoParams?
        var frames: [VideoFrame] = []
        for packet in try packets(for: encoded, channel: mac) {
            let message = try iPhone.open(packet, allowed: allowed, wallClock: wall, now: t0)
            switch message.type {
            case .videoParams: params = try VideoParams(payload: message.payload)
            case .videoFragment: if let frame = try assembler.add(message.payload, now: t0) { frames.append(frame) }
            default: XCTFail("type inattendu")
            }
        }

        XCTAssertEqual(frames.count, encoded.count)
        XCTAssertEqual(frames.map(\.data), encoded.map(\.data), "octets H.264 identiques de bout en bout")
        XCTAssertEqual(try decode(frames, params: try XCTUnwrap(params)), encoded.count, "chaque image se décode")
    }

    // MARK: - Attaques

    /// Un octet modifié dans un fragment vidéo : rejeté AVANT le décodeur, qui ne voit jamais de données forgées.
    func testTamperedVideoFragmentNeverReachesTheDecoder() throws {
        let (mac, iPhone) = channels()
        let all = try packets(for: try encode(frames: 3), channel: mac)
        var forged = try XCTUnwrap(all.last)
        forged[Limits.headerSize + 20] ^= 0x01
        for packet in all.dropLast() {
            _ = try iPhone.open(packet, allowed: allowed, wallClock: wall, now: t0)
        }
        XCTAssertThrowsError(try iPhone.open(forged, allowed: allowed, wallClock: wall, now: t0)) {
            XCTAssertEqual($0 as? ChannelError, .authenticationFailed)
        }
    }

    /// Un fragment vidéo capturé puis renvoyé (image figée rejouée) : refusé par le compteur.
    func testReplayedVideoFragmentIsRejected() throws {
        let (mac, iPhone) = channels()
        let all = try packets(for: try encode(frames: 2), channel: mac)
        for packet in all { _ = try iPhone.open(packet, allowed: allowed, wallClock: wall, now: t0) }
        XCTAssertThrowsError(try iPhone.open(try XCTUnwrap(all.last), allowed: allowed, wallClock: wall, now: t0)) {
            XCTAssertEqual($0 as? ChannelError, .badCounter)
        }
    }
}
#endif
