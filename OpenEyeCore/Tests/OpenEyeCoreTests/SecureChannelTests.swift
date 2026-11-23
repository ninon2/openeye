import CryptoKit
import XCTest
@testable import OpenEyeCore

/// Clé logicielle, réservée aux tests.
struct TestSigner: Signer {
    let key = P256.Signing.PrivateKey()
    var publicKey: P256.Signing.PublicKey { key.publicKey }
    func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

/// Simule Face ID annulé.
struct CancelledSigner: Signer {
    struct Cancelled: Error {}
    let publicKey: P256.Signing.PublicKey
    func sign(_ message: Data) throws -> Data { throw Cancelled() }
}

final class SecureChannelTests: XCTestCase {
    private let t0 = ContinuousClock().now
    private let wall: UInt64 = 1_700_000_000_000
    private let all = Set(FrameType.allCases)

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { hex(Data($0)) } }

    /// Valeurs factices et publiques, choisies pour le vecteur connu.
    private func vectorKeys() throws -> (hash: Data, iPhone: SessionKeys, mac: SessionKeys) {
        func scalar(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
        let macIdentity = try P256.Signing.PrivateKey(rawRepresentation: scalar(0x11))
        let parentIdentity = try P256.Signing.PrivateKey(rawRepresentation: scalar(0x22))
        let eI = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar(0x33))
        let eM = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar(0x44))
        let hash = Transcript.session(
            macIdentity: macIdentity.publicKey.x963Representation,
            parentIdentity: parentIdentity.publicKey.x963Representation,
            iPhoneEphemeral: eI.publicKey.x963Representation, iPhoneNonce: scalar(0x55),
            macEphemeral: eM.publicKey.x963Representation, macNonce: scalar(0x66)
        )
        return (
            hash,
            try SessionKeys.derive(ephemeral: eI, peerEphemeral: eM.publicKey, transcriptHash: hash),
            try SessionKeys.derive(ephemeral: eM, peerEphemeral: eI.publicKey, transcriptHash: hash)
        )
    }

    private func channels(macLastSent: UInt64 = 0) throws -> (mac: SecureChannel, iPhone: SecureChannel) {
        let keys = try vectorKeys()
        return (
            SecureChannel(localRole: .mac, keys: keys.mac, openedAt: t0, lastSent: macLastSent),
            SecureChannel(localRole: .iphone, keys: keys.iPhone, openedAt: t0)
        )
    }

    private func assertRejected(
        _ packet: Data, by channel: SecureChannel, as expected: ChannelError,
        allowed: Set<FrameType>? = nil, wall: UInt64? = nil, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try channel.open(packet, allowed: allowed ?? all, wallClock: wall ?? self.wall, now: t0), line: line
        ) { XCTAssertEqual($0 as? ChannelError, expected, line: line) }
    }

    // MARK: - Vecteur connu

    /// Valeurs calculées avec une autre bibliothèque (Python « cryptography »), pas avec ce code.
    func testKnownVector() throws {
        let keys = try vectorKeys()
        XCTAssertEqual(hex(keys.hash), "9e030e81aea01960ffad8ba69c60e2e83d2f00d668f6a2affa46c0f347be9512")
        for side in [keys.iPhone, keys.mac] {
            XCTAssertEqual(hex(side.macToIPhone), "44f40ae4347c8d9beecc8e075832328a1dcdbf6179d4c614fb2a6bad76e06ed8")
            XCTAssertEqual(hex(side.iPhoneToMac), "b59e4888a4444e61b9bbd7f05cce1a573bc7ca27e802963a020034170ea74e9c")
            XCTAssertEqual(side.sessionID, 0x8e55_1ece_2b34_8f65)
        }
        let packet = try channels().mac.seal(.sessionReady, timestamp: wall, now: t0)
        XCTAssertEqual(
            hex(packet),
            "4f4501108e551ece2b348f65000000000000000100000008cdbe3a75ee271210329f77f1b54a079b20b3e03c1448b9ca"
        )
    }

    func testLengthPrefixRemovesAmbiguity() {
        let a = Transcript.lengthPrefixed(Data("ab".utf8)) + Transcript.lengthPrefixed(Data("c".utf8))
        let b = Transcript.lengthPrefixed(Data("a".utf8)) + Transcript.lengthPrefixed(Data("bc".utf8))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Usage normal

    func testBothDirections() throws {
        let (mac, iPhone) = try channels()
        for step in UInt64(0)..<3 {
            let packet = try mac.seal(.sessionReady, timestamp: wall + step, now: t0)
            XCTAssertEqual(
                try iPhone.open(packet, allowed: all, wallClock: wall, now: t0),
                SecureMessage(type: .sessionReady, timestamp: wall + step, payload: Data())
            )
        }
        let close = try iPhone.seal(.close, payload: Data([7]), timestamp: wall, now: t0)
        XCTAssertEqual(try mac.open(close, allowed: all, wallClock: wall, now: t0).payload, Data([7]))
    }

    /// Deux paquets identiques donnent deux chiffrés différents : le nonce a changé.
    func testSamePlaintextNeverGivesSameCiphertext() throws {
        let (mac, _) = try channels()
        let first = try mac.seal(.sessionReady, timestamp: wall, now: t0)
        let second = try mac.seal(.sessionReady, timestamp: wall, now: t0)
        XCTAssertNotEqual(first.suffix(24), second.suffix(24))
    }

    // MARK: - Attaques

    func testReplayIsRejected() throws {
        let (mac, iPhone) = try channels()
        let packet = try mac.seal(.sessionReady, timestamp: wall, now: t0)
        _ = try iPhone.open(packet, allowed: all, wallClock: wall, now: t0)
        assertRejected(packet, by: iPhone, as: .badCounter)
    }

    func testMissingPacketIsDetected() throws {
        let (mac, iPhone) = try channels()
        _ = try mac.seal(.sessionReady, timestamp: wall, now: t0)
        assertRejected(try mac.seal(.sessionReady, timestamp: wall, now: t0), by: iPhone, as: .badCounter)
    }

    /// Chaque octet modifié, en-tête compris, est refusé. Le vrai paquet passe ensuite.
    func testEveryModifiedByteIsRejected() throws {
        for index in 0..<48 {
            let (mac, iPhone) = try channels()
            let packet = try mac.seal(.sessionReady, timestamp: wall, now: t0)
            XCTAssertEqual(packet.count, 48)
            var modified = packet
            modified[index] ^= 0x01
            XCTAssertThrowsError(try iPhone.open(modified, allowed: all, wallClock: wall, now: t0), "octet \(index)")
            XCTAssertNoThrow(try iPhone.open(packet, allowed: all, wallClock: wall, now: t0), "octet \(index)")
        }
    }

    /// Heartbeat et JournalAnchorProof ont le même sens et la même taille : changer le type passe
    /// les étapes 1 à 6. Seule l'authentification de l'en-tête (AAD) peut le détecter.
    func testHeaderIsAuthenticated() throws {
        let (mac, iPhone) = try channels()
        var packet = try mac.seal(.heartbeat, payload: Data(count: 41), timestamp: wall, now: t0)
        packet[3] = FrameType.journalAnchorProof.rawValue
        assertRejected(packet, by: iPhone, as: .authenticationFailed)
    }

    func testReflectionIsRejected() throws {
        let (mac, _) = try channels()
        let packet = try mac.seal(.close, payload: Data([0]), timestamp: wall, now: t0)
        // Close est permis dans les deux sens : seule la clé propre à chaque sens protège.
        assertRejected(packet, by: mac, as: .authenticationFailed)
    }

    func testPacketFromAnotherSessionIsRejected() throws {
        let (_, iPhone) = try channels()
        let other = SecureChannel(
            localRole: .mac,
            keys: SessionKeys(macToIPhone: SymmetricKey(size: .bits256), iPhoneToMac: SymmetricKey(size: .bits256), sessionID: 1),
            openedAt: t0
        )
        assertRejected(try other.seal(.sessionReady, timestamp: wall, now: t0), by: iPhone, as: .wrongSession)
    }

    func testClearFrameIsRejectedInsideSession() throws {
        let (_, iPhone) = try channels()
        let header = try FrameHeader(type: .reject, sessionID: 0, counter: 0, bodyLength: 1)
        let packet = try FrameCodec.encode(header: header, body: Data([0]))
        XCTAssertThrowsError(try iPhone.open(packet, allowed: all, wallClock: wall, now: t0)) {
            XCTAssertEqual($0 as? FrameError, .unexpectedType)
        }
    }

    func testForgedCounterDoesNotBlockRealPackets() throws {
        let (mac, iPhone) = try channels()
        let real = try mac.seal(.sessionReady, timestamp: wall, now: t0)
        var forged = real
        forged.replaceSubrange(12..<20, with: [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        assertRejected(forged, by: iPhone, as: .badCounter)
        XCTAssertNoThrow(try iPhone.open(real, allowed: all, wallClock: wall, now: t0))
    }

    // MARK: - Horodatage

    func testTimestampTolerance() throws {
        let tolerance = Limits.clockToleranceMilliseconds
        for (clock, accepted) in [
            (wall + tolerance, true), (wall - tolerance, true),
            (wall + tolerance + 1, false), (wall - tolerance - 1, false),
        ] {
            let (mac, iPhone) = try channels()
            let packet = try mac.seal(.sessionReady, timestamp: wall, now: t0)
            if accepted {
                XCTAssertNoThrow(try iPhone.open(packet, allowed: all, wallClock: clock, now: t0))
            } else {
                assertRejected(packet, by: iPhone, as: .badTimestamp, wall: clock)
            }
        }
    }

    func testTimestampCannotGoBackwards() throws {
        let (mac, iPhone) = try channels()
        _ = try iPhone.open(
            try mac.seal(.sessionReady, timestamp: wall, now: t0), allowed: all, wallClock: wall, now: t0
        )
        assertRejected(try mac.seal(.sessionReady, timestamp: wall - 1, now: t0), by: iPhone, as: .badTimestamp)
    }

    func testExtremeTimestampsDoNotCrash() throws {
        for value in [UInt64.min, UInt64.max] {
            let (mac, iPhone) = try channels()
            assertRejected(try mac.seal(.sessionReady, timestamp: value, now: t0), by: iPhone, as: .badTimestamp)
        }
    }

    // MARK: - Fermeture

    func testSessionClosesAtTwentiethFailure() throws {
        let (_, iPhone) = try channels()
        for _ in 1...19 { XCTAssertThrowsError(try iPhone.open(Data(), allowed: all, wallClock: wall, now: t0)) }
        XCTAssertFalse(iPhone.isClosed)
        XCTAssertThrowsError(try iPhone.open(Data(), allowed: all, wallClock: wall, now: t0))
        XCTAssertTrue(iPhone.isClosed)
    }

    func testOldFailuresAreForgotten() throws {
        let (_, iPhone) = try channels()
        for _ in 1...19 { XCTAssertThrowsError(try iPhone.open(Data(), allowed: all, wallClock: wall, now: t0)) }
        let later = t0.advanced(by: Limits.failureWindow)
        XCTAssertThrowsError(try iPhone.open(Data(), allowed: all, wallClock: wall, now: later))
        XCTAssertFalse(iPhone.isClosed)
    }

    func testClosedChannelRefusesEverything() throws {
        let (mac, iPhone) = try channels()
        let packet = try mac.seal(.sessionReady, timestamp: wall, now: t0)
        iPhone.close()
        assertRejected(packet, by: iPhone, as: .closed)
        XCTAssertThrowsError(try iPhone.seal(.keepalive, timestamp: wall, now: t0)) {
            XCTAssertEqual($0 as? ChannelError, .closed)
        }
    }

    func testSessionExpires() throws {
        let (mac, _) = try channels()
        XCTAssertNoThrow(try mac.seal(.sessionReady, timestamp: wall, now: t0.advanced(by: .seconds(3_599))))
        XCTAssertThrowsError(try mac.seal(.sessionReady, timestamp: wall, now: t0.advanced(by: .seconds(3_600)))) {
            XCTAssertEqual($0 as? ChannelError, .sessionExpired)
        }
        XCTAssertTrue(mac.isClosed)
    }

    func testCounterExhaustionClosesSession() throws {
        let (mac, _) = try channels(macLastSent: Limits.counterLimit - 2)
        XCTAssertNoThrow(try mac.seal(.sessionReady, timestamp: wall, now: t0))
        XCTAssertThrowsError(try mac.seal(.sessionReady, timestamp: wall, now: t0)) {
            XCTAssertEqual($0 as? ChannelError, .counterExhausted)
        }
        XCTAssertTrue(mac.isClosed)
    }

    func testCannotSealForeignOrClearTypes() throws {
        let (mac, iPhone) = try channels()
        XCTAssertThrowsError(try mac.seal(.keepalive, timestamp: wall, now: t0))
        XCTAssertThrowsError(try iPhone.seal(.sessionReady, timestamp: wall, now: t0))
        XCTAssertThrowsError(try iPhone.seal(.hello, timestamp: wall, now: t0))
    }
}
