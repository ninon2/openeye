import Foundation

/// Côté Mac : découpe une image encodée en corps de paquets VideoFragment. Ne conserve aucune image.
public struct FrameSplitter {
    private var lastFrameID: UInt32 = 0

    public init() {}

    public mutating func split(_ frame: Data, isKeyFrame: Bool) throws -> [Data] {
        guard !frame.isEmpty else { throw VideoError.emptyFrame }
        guard frame.count <= Limits.maxFrameSize else { throw VideoError.frameTooLarge }
        guard lastFrameID < .max else { throw VideoError.frameIDExhausted }
        lastFrameID += 1

        let size = Limits.maxFragmentData
        let count = (frame.count + size - 1) / size
        return (0..<count).map { index in
            VideoFragment(
                frameID: lastFrameID, index: index, count: count, isKeyFrame: isKeyFrame,
                data: Data(frame.dropFirst(index * size).prefix(size))
            ).payload
        }
    }
}
