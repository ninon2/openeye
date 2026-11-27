import CryptoKit
import XCTest
@testable import OpenEyeCore

/// Parcours complet en mémoire : les deux appareils n'échangent que des octets, comme sur le réseau.
/// Ne remplace pas les essais réels : ni Secure Enclave, ni Multipeer, ni vraie vidéo ici.
final class EndToEndTests: XCTestCase {
    private let t0 = ContinuousClock().now
    private let wall: UInt64 = 1_700_000_000_000
    private let phoneKey = TestSigner()
    private let macKey = TestSigner()

    /// Tout ce qu'un espion verrait passer.
    private final class Wire {
        var captured: [Data] = []
        func carry(_ packet: Data) -> Data {
            captured.append(packet)
            return packet
        }
    }

    private func pair(over wire: Wire) throws -> (mac: P256.Signing.PublicKey, parent: P256.Signing.PublicKey) {
        let computer = MacPairing(mac: macKey, wallClock: wall / 1_000, now: t0)
        // Le QR passe par la caméra, pas par le réseau.
        let qr = try QRPayload(text: try XCTUnwrap(computer.qrText), now: wall / 1_000)
        let phone = ParentPairing(parent: phoneKey, qr: qr)

        let nonce = wire.carry(try computer.makeNonce(request: wire.carry(try phone.makeRequest()), now: t0))
        let revealed = try phone.reveal(nonce: nonce)
        let macCode = try computer.verify(reveal: wire.carry(revealed.reveal), now: t0)
        let codesMatch = macCode == revealed.code
        XCTAssertTrue(codesMatch)
        let confirmed = try computer.confirm(codesMatch: codesMatch, now: t0)
        let mac = try phone.finish(accept: wire.carry(confirmed.accept), codesMatch: codesMatch)
        return (mac, confirmed.parentIdentity)
    }

    private func openSession(
        over wire: Wire, mac: P256.Signing.PublicKey, parent: P256.Signing.PublicKey
    ) throws -> (phone: SecureChannel, computer: SecureChannel) {
        let phone = ParentHandshake(parent: phoneKey, macIdentity: mac)
        let computer = MacHandshake(mac: macKey, parentIdentity: parent)
        let hello = wire.carry(try phone.makeHello())
        let challenge = wire.carry(try computer.makeChallenge(hello: hello, now: t0))
        let answer = try phone.answer(challenge: challenge, now: { self.t0 })
        let session = try computer.accept(auth: wire.carry(answer.auth), now: t0)

        let ready = wire.carry(try session.channel.seal(.sessionReady, timestamp: wall, now: t0))
        _ = try answer.channel.open(ready, allowed: [.sessionReady], wallClock: wall, now: t0)
        let keepalive = wire.carry(try answer.channel.seal(.keepalive, timestamp: wall, now: t0))
        _ = try session.channel.open(keepalive, allowed: [.keepalive], wallClock: wall, now: t0)
        return (answer.channel, session.channel)
    }

    private func fakeFrame(_ size: Int, marker: String) -> Data {
        Data(Data(repeating: 0, count: 100) + Data(marker.utf8) + Data(count: size))
    }

    func testFullJourney() throws {
        let wire = Wire()
        let identities = try pair(over: wire)
        let (phone, computer) = try openSession(over: wire, mac: identities.mac, parent: identities.parent)

        // Le Mac annonce la vidéo, puis envoie une image clé et trois images suivantes.
        let params = try VideoParams(width: 960, height: 600, sps: Data([0x67, 1, 2, 3]), pps: Data([0x68, 4]))
        let paramsPacket = wire.carry(try computer.seal(.videoParams, payload: params.payload, timestamp: wall, now: t0))
        let received = try phone.open(paramsPacket, allowed: [.videoParams], wallClock: wall, now: t0)
        XCTAssertEqual(try VideoParams(payload: received.payload), params)

        let marker = "IMAGE-FICTIVE-OPENEYE"
        var splitter = FrameSplitter(), assembler = FrameAssembler()
        for (position, size) in [100_000, 2_000, 30_000, 1].enumerated() {
            let frame = fakeFrame(size, marker: marker)
            var shown: VideoFrame?
            for payload in try splitter.split(frame, isKeyFrame: position == 0) {
                let packet = wire.carry(try computer.seal(.videoFragment, payload: payload, timestamp: wall, now: t0))
                let message = try phone.open(packet, allowed: [.videoFragment], wallClock: wall, now: t0)
                shown = try assembler.add(message.payload, now: t0)
            }
            XCTAssertEqual(shown?.data, frame)
        }

        // L'espion ne voit jamais le contenu de l'écran.
        for packet in wire.captured {
            XCTAssertNil(packet.range(of: Data(marker.utf8)))
        }

        // Le parent arrête : clés oubliées des deux côtés, aucune image en mémoire.
        let close = wire.carry(try phone.seal(.close, payload: Data([0]), timestamp: wall, now: t0))
        XCTAssertEqual(try computer.open(close, allowed: [.close, .keepalive], wallClock: wall, now: t0).type, .close)
        phone.close()
        computer.close()
        assembler.reset()
        XCTAssertEqual(assembler.pendingBytes, 0)
        XCTAssertThrowsError(try computer.seal(.videoFragment, payload: Data(count: 10), timestamp: wall, now: t0))
    }

    /// Démo J5 : toute une séance capturée, puis rejouée sur une nouvelle séance.
    func testReplayOfAWholeSessionIsRefused() throws {
        let wire = Wire()
        let identities = try pair(over: wire)
        _ = try openSession(over: wire, mac: identities.mac, parent: identities.parent)
        let recorded = wire.captured

        let (phone, computer) = try openSession(over: Wire(), mac: identities.mac, parent: identities.parent)
        let all = Set(FrameType.allCases)
        for packet in recorded {
            XCTAssertThrowsError(try phone.open(packet, allowed: all, wallClock: wall, now: t0))
            XCTAssertThrowsError(try computer.open(packet, allowed: all, wallClock: wall, now: t0))
        }
        // Moins de 20 rejets : la vraie séance continue.
        let packet = try computer.seal(.close, payload: Data([0]), timestamp: wall, now: t0)
        XCTAssertNoThrow(try phone.open(packet, allowed: all, wallClock: wall, now: t0))
    }

    /// Sans les bonnes clés appairées, pas de séance.
    func testUnpairedDevicesCannotConnect() throws {
        let identities = try pair(over: Wire())
        let strangerPhone = ParentHandshake(parent: TestSigner(), macIdentity: identities.mac)
        XCTAssertThrowsError(
            try MacHandshake(mac: macKey, parentIdentity: identities.parent)
                .makeChallenge(hello: strangerPhone.makeHello(), now: t0)
        )
        let phone = ParentHandshake(parent: phoneKey, macIdentity: identities.mac)
        let strangerMac = MacHandshake(mac: TestSigner(), parentIdentity: identities.parent)
        let challenge = try strangerMac.makeChallenge(hello: phone.makeHello(), now: t0)
        XCTAssertThrowsError(try phone.answer(challenge: challenge, now: { self.t0 }))
    }
}
