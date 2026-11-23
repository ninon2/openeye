import Foundation

public enum VideoError: Error, Equatable, Sendable {
    case invalidParams
    case invalidFragment
    case inconsistentFragment
    case emptyFrame
    case frameTooLarge
    case frameIDExhausted
}

/// Réglages du décodeur H.264, envoyés avant chaque image clé (docs/protocole.md §4.3).
public struct VideoParams: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let sps: Data
    public let pps: Data

    public init(width: Int, height: Int, sps: Data, pps: Data) throws {
        let dimensions = 2...Limits.maxVideoDimension
        // 16 = horodatage (8) + largeur, hauteur et deux longueurs (4 × 2).
        guard dimensions.contains(width), dimensions.contains(height), width % 2 == 0, height % 2 == 0,
              !sps.isEmpty, !pps.isEmpty,
              16 + sps.count + pps.count <= Limits.maxVideoParamsBody
        else { throw VideoError.invalidParams }
        self.width = width
        self.height = height
        self.sps = sps
        self.pps = pps
    }

    /// Corps sans l'horodatage, qui est ajouté par `SecureChannel`.
    public var payload: Data {
        Data(FrameCodec.bigEndian(UInt64(width), byteCount: 2))
            + Data(FrameCodec.bigEndian(UInt64(height), byteCount: 2))
            + Transcript.lengthPrefixed(sps) + Transcript.lengthPrefixed(pps)
    }

    public init(payload: Data) throws {
        let bytes = [UInt8](payload)
        // Chaque longueur annoncée est comparée à la taille réelle AVANT de découper.
        guard bytes.count >= 6 else { throw VideoError.invalidParams }
        let spsEnd = 6 + Self.number(bytes[4..<6])
        guard bytes.count >= spsEnd + 2 else { throw VideoError.invalidParams }
        let ppsStart = spsEnd + 2
        // Égalité stricte : aucun octet en trop.
        guard bytes.count == ppsStart + Self.number(bytes[spsEnd..<ppsStart]) else {
            throw VideoError.invalidParams
        }
        try self.init(
            width: Self.number(bytes[0..<2]), height: Self.number(bytes[2..<4]),
            sps: Data(bytes[6..<spsEnd]), pps: Data(bytes[ppsStart...])
        )
    }

    private static func number(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }
}

/// Morceau d'une image encodée.
struct VideoFragment: Equatable {
    static let fixedSize = 9

    let frameID: UInt32
    let index: Int
    let count: Int
    let isKeyFrame: Bool
    let data: Data

    var payload: Data {
        Data(FrameCodec.bigEndian(UInt64(frameID), byteCount: 4))
            + Data(FrameCodec.bigEndian(UInt64(index), byteCount: 2))
            + Data(FrameCodec.bigEndian(UInt64(count), byteCount: 2))
            + Data([isKeyFrame ? 1 : 0]) + data
    }

    init(frameID: UInt32, index: Int, count: Int, isKeyFrame: Bool, data: Data) {
        self.frameID = frameID
        self.index = index
        self.count = count
        self.isKeyFrame = isKeyFrame
        self.data = data
    }

    init(payload: Data) throws {
        let bytes = [UInt8](payload)
        guard bytes.count > Self.fixedSize, bytes.count <= Self.fixedSize + Limits.maxFragmentData else {
            throw VideoError.invalidFragment
        }
        let frameID = bytes[0..<4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let index = Int(bytes[4]) << 8 | Int(bytes[5])
        let count = Int(bytes[6]) << 8 | Int(bytes[7])
        // Le numéro 0 est réservé, l'indice est dans les bornes, aucun drapeau inconnu.
        guard frameID > 0, (1...Limits.maxFragmentsPerFrame).contains(count), index < count, bytes[8] <= 1 else {
            throw VideoError.invalidFragment
        }
        self.init(
            frameID: frameID, index: index, count: count, isKeyFrame: bytes[8] == 1,
            data: Data(bytes[Self.fixedSize...])
        )
    }
}
