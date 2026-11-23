import CryptoKit
import XCTest
@testable import OpenEyeCore

final class HandshakeTests: XCTestCase {
    private let t0 = ContinuousClock().now
    private let parent = TestSigner()
    private let mac = TestSigner()

    private func iPhoneSide(macIdentity: P256.Signing.PublicKey? = nil) -> ParentHandshake {
        ParentHandshake(parent: parent, macIdentity: macIdentity ?? mac.publicKey)
    }

    private func macSide() -> MacHandshake {
        MacHandshake(mac: mac, parentIdentity: parent.publicKey)
    }

    private func assertFails<T>(
        _ expected: HandshakeError, line: UInt = #line, _ body: () throws -> T
    ) {
        XCTAssertThrowsError(try body(), line: line) {
            XCTAssertEqual($0 as? HandshakeError, expected, line: line)
        }
    }

    // MARK: - Réussite

    func testSuccessOpensMatchingChannels() throws {
        let iPhone = iPhoneSide(), computer = macSide()
        let challenge = try computer.makeChallenge(hello: iPhone.makeHello(), now: t0)
        let answer = try iPhone.answer(challenge: challenge, now: { self.t0 })
        let session = try computer.accept(auth: answer.auth, now: t0)

        let ready = try session.channel.seal(.sessionReady, timestamp: 1_000, now: t0)
        XCTAssertEqual(
            try answer.channel.open(ready, allowed: [.sessionReady], wallClock: 1_000, now: t0).type, .sessionReady
        )
        let keepalive = try answer.channel.seal(.keepalive, timestamp: 1_000, now: t0)
        XCTAssertNoThrow(try session.channel.open(keepalive, allowed: [.keepalive], wallClock: 1_000, now: t0))

        // R1 : la preuve conservée au journal se vérifie avec la seule clé publique du parent.
        let proof = try P256.Signing.ECDSASignature(rawRepresentation: session.parentSignature)
        XCTAssertTrue(parent.publicKey.isValidSignature(
            proof, for: Data("OpenEye/v1/sess-parent".utf8) + session.transcriptHash
        ))
    }

    func testTwoSessionsNeverShareTheirIdentifier() throws {
        var ids = Set<UInt64>()
        for _ in 0..<5 {
            let iPhone = iPhoneSide(), computer = macSide()
            let challenge = try computer.makeChallenge(hello: iPhone.makeHello(), now: t0)
            ids.insert(try iPhone.answer(challenge: challenge, now: { self.t0 }).channel.sessionID)
        }
        XCTAssertEqual(ids.count, 5)
    }

    // MARK: - Usurpation (S1, S2, S5)

    func testUnknownParentIsRejected() throws {
        let intruder = ParentHandshake(parent: TestSigner(), macIdentity: mac.publicKey)
        assertFails(.unknownParent) { try macSide().makeChallenge(hello: intruder.makeHello(), now: t0) }
    }

    /// L'intrus connaît l'empreinte du parent (publique) mais pas sa clé.
    func testStolenFingerprintIsNotEnough() throws {
        struct Impostor: Signer {
            let publicKey: P256.Signing.PublicKey
            let key = P256.Signing.PrivateKey()
            func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
        }
        let intruder = ParentHandshake(parent: Impostor(publicKey: parent.publicKey), macIdentity: mac.publicKey)
        let computer = macSide()
        let challenge = try computer.makeChallenge(hello: intruder.makeHello(), now: t0)
        let auth = try intruder.answer(challenge: challenge, now: { self.t0 }).auth
        assertFails(.invalidSignature) { try computer.accept(auth: auth, now: t0) }
    }

    func testFakeMacIsRejectedBeforeFaceID() throws {
        // Le signataire lèverait Cancelled si Face ID était demandé.
        let iPhone = ParentHandshake(
            parent: CancelledSigner(publicKey: parent.publicKey), macIdentity: mac.publicKey
        )
        let fakeMac = MacHandshake(mac: TestSigner(), parentIdentity: parent.publicKey)
        let challenge = try fakeMac.makeChallenge(hello: iPhone.makeHello(), now: t0)
        assertFails(.invalidSignature) { try iPhone.answer(challenge: challenge, now: { self.t0 }) }
    }

    /// Homme du milieu : il remplace la clé éphémère de l'iPhone dans Hello.
    func testSubstitutedIPhoneEphemeralIsDetected() throws {
        let iPhone = iPhoneSide(), computer = macSide()
        var hello = try iPhone.makeHello()
        hello.replaceSubrange(56..<121, with: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        let challenge = try computer.makeChallenge(hello: hello, now: t0)
        assertFails(.invalidSignature) { try iPhone.answer(challenge: challenge, now: { self.t0 }) }
    }

    /// Homme du milieu : il remplace la clé éphémère du Mac dans Challenge.
    func testSubstitutedMacEphemeralIsDetected() throws {
        let iPhone = iPhoneSide(), computer = macSide()
        var challenge = try computer.makeChallenge(hello: iPhone.makeHello(), now: t0)
        challenge.replaceSubrange(24..<89, with: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        assertFails(.invalidSignature) { try iPhone.answer(challenge: challenge, now: { self.t0 }) }
    }

    func testEphemeralOutsideTheCurveIsRejected() throws {
        var hello = try iPhoneSide().makeHello()
        hello.replaceSubrange(56..<121, with: [0x04] + [UInt8](repeating: 0xFF, count: 64))
        assertFails(.invalidKey) { try macSide().makeChallenge(hello: hello, now: t0) }
    }

    // MARK: - Rejeu et délais (E1, E2)

    func testOldAuthorizationIsRejectedByNewChallenge() throws {
        let iPhone = iPhoneSide(), first = macSide()
        let hello = try iPhone.makeHello()
        let oldAuth = try iPhone.answer(
            challenge: first.makeChallenge(hello: hello, now: t0), now: { self.t0 }
        ).auth
        // Un attaquant rejoue Hello puis l'ancien Auth dans une nouvelle tentative.
        let second = macSide()
        _ = try second.makeChallenge(hello: hello, now: t0)
        assertFails(.invalidSignature) { try second.accept(auth: oldAuth, now: t0) }
    }

    func testChallengeCanOnlyBeUsedOnce() throws {
        let iPhone = iPhoneSide(), computer = macSide()
        let challenge = try computer.makeChallenge(hello: iPhone.makeHello(), now: t0)
        let auth = try iPhone.answer(challenge: challenge, now: { self.t0 }).auth
        _ = try computer.accept(auth: auth, now: t0)
        assertFails(.invalidState) { try computer.accept(auth: auth, now: t0) }
    }

    /// Une mauvaise réponse brûle le défi : pas de second essai, même avec la bonne signature.
    func testWrongAnswerBurnsTheChallenge() throws {
        let iPhone = iPhoneSide(), computer = macSide()
        let challenge = try computer.makeChallenge(hello: iPhone.makeHello(), now: t0)
        let auth = try iPhone.answer(challenge: challenge, now: { self.t0 }).auth
        var wrong = auth
        wrong[40] ^= 0x01
        assertFails(.invalidSignature) { try computer.accept(auth: wrong, now: t0) }
        assertFails(.invalidState) { try computer.accept(auth: auth, now: t0) }
    }

    func testChallengeExpiresAfterThirtySeconds() throws {
        for (seconds, accepted) in [(29, true), (30, false)] {
            let iPhone = iPhoneSide(), computer = macSide()
            let challenge = try computer.makeChallenge(hello: iPhone.makeHello(), now: t0)
            let auth = try iPhone.answer(challenge: challenge, now: { self.t0 }).auth
            let later = t0.advanced(by: .seconds(seconds))
            if accepted {
                XCTAssertNoThrow(try computer.accept(auth: auth, now: later))
            } else {
                assertFails(.challengeExpired) { try computer.accept(auth: auth, now: later) }
            }
        }
    }

    func testCancelledFaceIDProducesNothing() throws {
        let iPhone = ParentHandshake(
            parent: CancelledSigner(publicKey: parent.publicKey), macIdentity: mac.publicKey
        )
        let challenge = try macSide().makeChallenge(hello: iPhone.makeHello(), now: t0)
        XCTAssertThrowsError(try iPhone.answer(challenge: challenge, now: { self.t0 })) {
            XCTAssertTrue($0 is CancelledSigner.Cancelled)
        }
        // La tentative est terminée : il faut tout recommencer.
        assertFails(.invalidState) { try iPhone.answer(challenge: challenge, now: { self.t0 }) }
    }

    // MARK: - Séparation de domaine et ordre

    /// La signature du Mac ne peut pas servir de signature du parent, même à clé identique.
    func testSignatureLabelsAreNotInterchangeable() throws {
        let iPhone = ParentHandshake(parent: mac, macIdentity: mac.publicKey)
        let computer = MacHandshake(mac: mac, parentIdentity: mac.publicKey)
        let challenge = try computer.makeChallenge(hello: iPhone.makeHello(), now: t0)
        let header = try FrameHeader(type: .auth, sessionID: 0, counter: 0, bodyLength: 64)
        let reused = try FrameCodec.encode(header: header, body: Data(challenge.suffix(64)))
        assertFails(.invalidSignature) { try computer.accept(auth: reused, now: t0) }
    }

    func testStepsOutOfOrderAreRejected() throws {
        assertFails(.invalidState) { try iPhoneSide().answer(challenge: Data(), now: { self.t0 }) }
        assertFails(.invalidState) { try macSide().accept(auth: Data(), now: t0) }

        let iPhone = iPhoneSide()
        _ = try iPhone.makeHello()
        assertFails(.invalidState) { try iPhone.makeHello() }

        let computer = macSide()
        let hello = try iPhoneSide().makeHello()
        _ = try computer.makeChallenge(hello: hello, now: t0)
        assertFails(.invalidState) { try computer.makeChallenge(hello: hello, now: t0) }
    }

    func testMalformedPacketsAreRejected() throws {
        XCTAssertThrowsError(try macSide().makeChallenge(hello: Data(), now: t0))
        let iPhone = iPhoneSide()
        _ = try iPhone.makeHello()
        XCTAssertThrowsError(try iPhone.answer(challenge: Data(count: 185), now: { self.t0 }))
    }
}
