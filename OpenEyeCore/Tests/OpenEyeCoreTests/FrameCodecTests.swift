import XCTest
@testable import OpenEyeCore

final class FrameCodecTests: XCTestCase {
    private let all = Set(FrameType.allCases)

    // MARK: - Aides

    private func sender(of type: FrameType) -> Sender {
        type.canBeSent(by: .mac) ? .mac : .iphone
    }

    private func packet(_ type: FrameType, bodySize: Int? = nil) throws -> Data {
        let size = bodySize ?? type.bodySize.lowerBound
        let header = try FrameHeader(
            type: type,
            sessionID: type.isEncrypted ? 0x0102030405060708 : 0,
            counter: type.isEncrypted ? 1 : 0,
            bodyLength: size
        )
        return try FrameCodec.encode(
            header: header,
            body: Data(repeating: 0xAB, count: size),
            tag: Data(repeating: 0xCD, count: type.isEncrypted ? Limits.tagSize : 0)
        )
    }

    private func assertRejected(
        _ data: Data, from sender: Sender, allowed: Set<FrameType>? = nil,
        as expected: FrameError, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try FrameCodec.decode(data, from: sender, allowed: allowed ?? all), line: line
        ) { XCTAssertEqual($0 as? FrameError, expected, line: line) }
    }

    // MARK: - Cas valides

    /// Vecteur écrit à la main depuis la spec, pas produit par le codec testé.
    func testKnownHeaderVector() throws {
        let header = try FrameHeader(type: .keepalive, sessionID: 0x0102030405060708, counter: 0x0A, bodyLength: 8)
        XCTAssertEqual([UInt8](header.encoded), [
            0x4F, 0x45, 0x01, 0x14,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A,
            0x00, 0x00, 0x00, 0x08,
        ])
    }

    func testRoundTripForEveryTypeAtBothBounds() throws {
        for type in FrameType.allCases {
            for size in [type.bodySize.lowerBound, type.bodySize.upperBound] {
                let data = try packet(type, bodySize: size)
                let frame = try FrameCodec.decode(data, from: sender(of: type), allowed: [type])
                XCTAssertEqual(frame.header.type, type)
                XCTAssertEqual(frame.body.count, size)
                XCTAssertEqual(frame.tag.count, type.isEncrypted ? 16 : 0)
                XCTAssertEqual(try FrameCodec.encode(header: frame.header, body: frame.body, tag: frame.tag), data)
            }
        }
    }

    func testEveryValidPacketFitsInMaxPacketSize() {
        for type in FrameType.allCases {
            XCTAssertLessThanOrEqual(
                Limits.headerSize + type.bodySize.upperBound + Limits.tagSize, Limits.maxPacketSize
            )
        }
    }

    func testDataSliceWithNonZeroStartIndex() throws {
        let data = try packet(.keepalive)
        let slice = (Data([0xFF, 0xFF, 0xFF]) + data).dropFirst(3)
        XCTAssertEqual(
            try FrameCodec.decode(slice, from: .iphone, allowed: all),
            try FrameCodec.decode(data, from: .iphone, allowed: all)
        )
    }

    // MARK: - Étape 1 : taille

    func testRejectsTooShortPackets() throws {
        let data = try packet(.hello)
        for size in 0..<Limits.headerSize {
            assertRejected(data.prefix(size), from: .iphone, as: .badPacketSize)
        }
    }

    func testRejectsOversizedPacket() throws {
        let data = try packet(.videoFragment)
        let padding = Data(repeating: 0, count: Limits.maxPacketSize + 1 - data.count)
        assertRejected(data + padding, from: .mac, as: .badPacketSize)
    }

    // MARK: - Étape 2 : magic et version

    func testRejectsBadMagicAndVersion() throws {
        for (index, error) in [(0, FrameError.badMagic), (1, .badMagic), (2, .badVersion)] {
            var data = try packet(.hello)
            data[index] ^= 0xFF
            assertRejected(data, from: .iphone, as: error)
        }
    }

    // MARK: - Étape 3 : type

    /// Couvre aussi 0x18–0x1F et 0x25 et au-delà, autour des commandes 0x20–0x24.
    func testRejectsEveryUnknownType() throws {
        for raw in UInt8.min...UInt8.max where FrameType(rawValue: raw) == nil {
            var data = try packet(.hello)
            data[3] = raw
            assertRejected(data, from: .iphone, as: .unknownType)
        }
    }

    /// Réflexion : un paquet renvoyé à son émetteur est refusé.
    func testRejectsWrongDirection() throws {
        for type in FrameType.allCases where type != .close {
            let other: Sender = sender(of: type) == .mac ? .iphone : .mac
            assertRejected(try packet(type), from: other, as: .wrongDirection)
        }
    }

    func testRejectsTypeNotExpectedInCurrentState() throws {
        assertRejected(try packet(.videoFragment), from: .mac, allowed: [.sessionReady], as: .unexpectedType)
        assertRejected(try packet(.hello), from: .iphone, allowed: [], as: .unexpectedType)
    }

    // MARK: - Étape 4 : longueur

    func testRejectsAnnouncedLengthMismatch() throws {
        let lengths: [[UInt8]] = [[0, 0, 0, 0], [0, 0, 0, 7], [0, 0, 0, 9], [0xFF, 0xFF, 0xFF, 0xFF]]
        for length in lengths {
            var data = try packet(.keepalive)
            data.replaceSubrange(20..<24, with: length)
            assertRejected(data, from: .iphone, as: .badLength)
        }
    }

    func testRejectsTruncatedOrExtendedPacket() throws {
        let data = try packet(.keepalive)
        assertRejected(data.dropLast(), from: .iphone, as: .badLength)
        assertRejected(data + [0x00], from: .iphone, as: .badLength)
    }

    func testRejectsEncryptedPacketTooShortForItsTag() throws {
        assertRejected(try packet(.keepalive).prefix(Limits.headerSize + 15), from: .iphone, as: .badLength)
    }

    /// Longueur cohérente avec le paquet, mais interdite pour ce type.
    func testRejectsBodySizeForbiddenForType() throws {
        var data = try packet(.keepalive) + [0x00]
        data[23] = 9
        assertRejected(data, from: .iphone, as: .badBodySize)
    }

    // MARK: - Session et compteur

    func testRejectsClearPacketCarryingSessionOrCounter() throws {
        for index in [4, 11, 12, 19] {
            var data = try packet(.hello)
            data[index] = 1
            assertRejected(data, from: .iphone, as: .badClearHeader)
        }
    }

    func testRejectsCounterZeroOnEncryptedPacket() throws {
        var data = try packet(.keepalive)
        data[19] = 0
        assertRejected(data, from: .iphone, as: .badCounter)
    }

    // MARK: - Émission

    func testEncodeRefusesInconsistentParts() throws {
        let header = try FrameHeader(type: .keepalive, sessionID: 1, counter: 1, bodyLength: 8)
        XCTAssertThrowsError(try FrameCodec.encode(header: header, body: Data(count: 7), tag: Data(count: 16)))
        XCTAssertThrowsError(try FrameCodec.encode(header: header, body: Data(count: 8), tag: Data(count: 15)))
        XCTAssertThrowsError(try FrameHeader(type: .auth, sessionID: 0, counter: 0, bodyLength: 65))
        XCTAssertThrowsError(try FrameHeader(type: .auth, sessionID: 0, counter: 0, bodyLength: -1))
    }

    // MARK: - Données hostiles

    /// Paquets pseudo-aléatoires reproductibles (graine fixe, usage de test uniquement).
    /// Le décodeur doit refuser ou rendre un paquet cohérent, sans jamais planter.
    func testHostileInputNeverCrashes() {
        var state: UInt64 = 0x4F45
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        for round in 0..<20_000 {
            var bytes = (0..<Int(next() % 200)).map { _ in UInt8(truncatingIfNeeded: next()) }
            if round % 2 == 0, bytes.count >= 4 {
                // Une fois sur deux, on passe les étapes 2 et 3 pour atteindre la suite.
                bytes[0] = 0x4F
                bytes[1] = 0x45
                bytes[2] = 0x01
                bytes[3] = FrameType.allCases[Int(next()) % FrameType.allCases.count].rawValue
            }
            let sender: Sender = round % 4 < 2 ? .mac : .iphone
            if let frame = try? FrameCodec.decode(Data(bytes), from: sender, allowed: all) {
                XCTAssertTrue(frame.header.type.bodySize.contains(frame.body.count))
                XCTAssertTrue(frame.header.type.canBeSent(by: sender))
            }
        }
    }
}
