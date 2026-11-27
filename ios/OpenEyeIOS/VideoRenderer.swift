import AVFoundation
import CoreMedia
import OpenEyeCore
import SwiftUI

/// Décodage matériel et affichage du flux H.264 (docs/architecture.md §7).
/// Les images ne vivent qu'en mémoire : rien n'est écrit, rien n'est rejouable.
@MainActor
final class VideoRenderer {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    var hasFormat: Bool { format != nil }

    /// Paramètres reçus avant chaque image clé. Un format invalide est simplement ignoré.
    func configure(_ params: VideoParams) {
        format = Self.makeFormat(params)
    }

    /// Renvoie faux si l'image n'a pas pu être affichée : l'appelant attend alors une image clé.
    func display(_ frame: VideoFrame) -> Bool {
        guard let format, let sample = Self.makeSample(frame.data, format: format) else { return false }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
        return true
    }

    /// Fin de session ou arrière-plan : la dernière image est effacée de l'écran.
    func clear() {
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        format = nil
    }

    private static func makeFormat(_ params: VideoParams) -> CMVideoFormatDescription? {
        let sps = [UInt8](params.sps), pps = [UInt8](params.pps)
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer -> OSStatus in
                guard let spsBase = spsBuffer.baseAddress, let ppsBase = ppsBuffer.baseAddress else { return -1 }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format
                )
            }
        }
        return status == noErr ? format : nil
    }

    private static func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        // Direct : chaque image s'affiche dès son arrivée, sans horloge de lecture.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

/// Vue SwiftUI qui héberge la couche d'affichage.
struct VideoView: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.hostedLayer = renderer.layer
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}

    final class LayerHostView: UIView {
        var hostedLayer: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hostedLayer { layer.addSublayer(hostedLayer) }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hostedLayer?.frame = bounds
        }
    }
}
