import CryptoKit
import XCTest
@testable import OpenEyeCore

final class PairingTests: XCTestCase {
    private let t0 = ContinuousClock().now
    private let wall: UInt64 = 1_700_000_000
    private let parent = TestSigner()
    private let mac = TestSigner()

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func newMac() -> MacPairing { MacPairing(mac: mac, wallClock: wall, now: t0) }

    private func newParent(for pairing: MacPairing, signer: (any Signer)? = nil) throws -> ParentPairing {
        ParentPairing(parent: signer ?? parent, qr: try QRPayload(text: try XCTUnwrap(pairing.qrText), now: wall))
    }

    private func assertFails<T>(_ expected: PairingError, line: UInt = #line, _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), line: line) {
            XCTAssertEqual($0 as? PairingError, expected, line: line)
        }
    }

    // MARK: - Vecteur connu (calculé avec Python, pas avec ce code)

    func testKnownVector() throws {
        func identity(_ byte: UInt8) throws -> P256.Signing.PublicKey {
            try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32)).publicKey
        }
        let macIdentity = try identity(0x11), parentIdentity = try identity(0x22)
        let pairingID = Data(repeating: 0x77, count: 16)
        let secret = SymmetricKey(data: Data(repeating: 0x88, count: 32))
        let nI = Data(repeating: 0x55, count: 32), nM = Data(repeating: 0x66, count: 32)

        let text = QRPayload(pairingID: pairingID, secret: secret, expiry: 1_700_000_120, macIdentity: macIdentity).text
        XCTAssertEqual(text, "AXd3d3d3d3d3d3d3d3d3d3eIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiAAAAABlU_F4BAIX5hfwtkQ5KCePlpmeaaI6TywVK99tbN9m5bgCgtTtGUp968uXcS0t2jyoWqh2Wlb0X8dYWZZS8ol8ZTBuV5Q")

        let commitment = PairingMath.commitment(parentIdentity: parentIdentity.x963Representation, nonce: nI)
        XCTAssertEqual(hex(commitment), "505b51e4b81ab28b74ccefdd31bd16b2475ee1ef68c221d8e59058da43692330")

        let message = try PairingMath.requestMessage(
            pairingID: pairingID, parentIdentity: parentIdentity.x963Representation, commitment: commitment
        )
        let code = HMAC<SHA256>.authenticationCode(
            for: message, using: PairingMath.macKey(secret: secret, pairingID: pairingID)
        )
        XCTAssertEqual(hex(Data(code)), "66c11503bde9e4a2826cd8afd28aee22b9a1c250aed599cb7c1a19bbc766fbfc")

        let transcript = PairingMath.transcript(
            pairingID: pairingID, macIdentity: macIdentity.x963Representation,
            parentIdentity: parentIdentity.x963Representation, iPhoneNonce: nI, macNonce: nM
        )
        XCTAssertEqual(hex(transcript), "2b88f99bad6e7d5db4df07ce5ce4807985d582496818319eef707a707aee611d")
        XCTAssertEqual(PairingMath.code(transcript: transcript), "322635")
    }

    func testCodeAlwaysHasSixDigits() {
        for index in 0..<2_000 {
            let code = PairingMath.code(transcript: Data(FrameCodec.bigEndian(UInt64(index), byteCount: 8)))
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { $0.isASCII && $0.isNumber })
        }
    }

    // MARK: - Réussite

    func testSuccess() throws {
        let computer = newMac(), phone = try newParent(for: computer)
        let nonce = try computer.makeNonce(request: phone.makeRequest(), now: t0)
        let revealed = try phone.reveal(nonce: nonce)
        XCTAssertEqual(try computer.verify(reveal: revealed.reveal, now: t0), revealed.code)
        let result = try computer.confirm(codesMatch: true, now: t0)
        XCTAssertEqual(result.parentIdentity.x963Representation, parent.publicKey.x963Representation)
        XCTAssertEqual(
            try phone.finish(accept: result.accept, codesMatch: true).x963Representation,
            mac.publicKey.x963Representation
        )
    }

    // MARK: - QR hostile

    func testQRExpiry() throws {
        let text = try XCTUnwrap(newMac().qrText)
        XCTAssertNoThrow(try QRPayload(text: text, now: wall + 119))
        assertFails(.expired) { try QRPayload(text: text, now: wall + 120) }
        // Horloges décalées de 30 s au plus ; au-delà, durée anormale.
        XCTAssertNoThrow(try QRPayload(text: text, now: wall - 30))
        assertFails(.invalidQR) { try QRPayload(text: text, now: wall - 31) }
    }

    func testMalformedQRIsRejected() throws {
        let text = try XCTUnwrap(newMac().qrText)
        let tail1 = String(text.dropFirst(1))
        let tail2 = String(text.dropFirst(2))
        var bad: [String] = ["", "openeye"]
        bad.append(String(text.dropLast()))
        bad.append(text + "A")
        bad.append(text + "=")
        bad.append("!" + tail1)
        bad.append("é" + tail2)
        bad.append("Ag" + tail2) // version 2
        bad.append(String(repeating: "A", count: 100_000))
        for value in bad {
            XCTAssertThrowsError(try QRPayload(text: value, now: wall))
        }
    }

    func testQRWithKeyOutsideTheCurveIsRejected() {
        let bytes = Data([1]) + Data(count: 48) + Data(FrameCodec.bigEndian(wall + 100, byteCount: 8))
            + Data([0x04]) + Data(repeating: 0xFF, count: 64)
        let text = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        assertFails(.invalidKey) { try QRPayload(text: text, now: wall) }
    }

    // MARK: - Intrus (S4, S5)

    /// L'intrus n'a pas vu le QR : il ne connaît pas le secret.
    func testRequestWithoutTheSecretIsRejected() throws {
        let computer = newMac()
        let real = try QRPayload(text: try XCTUnwrap(computer.qrText), now: wall)
        let guessed = QRPayload(
            pairingID: real.pairingID, secret: SymmetricKey(size: .bits256),
            expiry: real.expiry, macIdentity: real.macIdentity
        )
        let intruder = ParentPairing(parent: TestSigner(), qr: guessed)
        assertFails(.invalidMAC) { try computer.makeNonce(request: intruder.makeRequest(), now: t0) }
    }

    func testEveryModifiedRequestByteIsRejected() throws {
        for index in 0..<(24 + 145) {
            let computer = newMac()
            var request = try newParent(for: computer).makeRequest()
            request[index] ^= 0x01
            XCTAssertThrowsError(try computer.makeNonce(request: request, now: t0), "octet \(index)")
        }
    }

    func testQRWorksOnlyOnce() throws {
        let computer = newMac()
        let first = try newParent(for: computer), second = try newParent(for: computer, signer: TestSigner())
        _ = try computer.makeNonce(request: first.makeRequest(), now: t0)
        XCTAssertNil(computer.qrText, "le secret du QR doit être oublié")
        assertFails(.invalidState) { try computer.makeNonce(request: second.makeRequest(), now: t0) }
    }

    func testFailedRequestBurnsTheQR() throws {
        let computer = newMac(), phone = try newParent(for: computer)
        let good = try phone.makeRequest()
        XCTAssertThrowsError(try computer.makeNonce(request: Data(), now: t0))
        assertFails(.invalidState) { try computer.makeNonce(request: good, now: t0) }
    }

    /// Le nonce révélé doit être celui promis : pas de recherche du code après coup.
    func testChangedNonceBreaksTheCommitment() throws {
        let computer = newMac(), phone = try newParent(for: computer)
        let nonce = try computer.makeNonce(request: phone.makeRequest(), now: t0)
        var reveal = try phone.reveal(nonce: nonce).reveal
        reveal[24 + 16] ^= 0x01
        assertFails(.invalidCommitment) { try computer.verify(reveal: reveal, now: t0) }
    }

    func testRevealWithWrongSignatureIsRejected() throws {
        let computer = newMac(), phone = try newParent(for: computer)
        let nonce = try computer.makeNonce(request: phone.makeRequest(), now: t0)
        var reveal = try phone.reveal(nonce: nonce).reveal
        reveal.replaceSubrange(72..<136, with: try TestSigner().sign(Data("autre".utf8)))
        assertFails(.invalidSignature) { try computer.verify(reveal: reveal, now: t0) }
    }

    /// Homme du milieu qui a photographié le QR : il appaire SA clé, et donne un faux nM à l'iPhone.
    func testManInTheMiddleIsVisibleOnBothSides() throws {
        let computer = newMac()
        let victim = try newParent(for: computer)
        let attacker = try newParent(for: computer, signer: TestSigner())

        _ = try victim.makeRequest() // interceptée, jamais transmise
        let realNonce = try computer.makeNonce(request: attacker.makeRequest(), now: t0)
        let attackerReveal = try attacker.reveal(nonce: realNonce)
        let macCode = try computer.verify(reveal: attackerReveal.reveal, now: t0)
        let victimCode = try victim.reveal(nonce: realNonce).code

        // 1. Les codes affichés diffèrent, à une chance sur un million près.
        XCTAssertNotEqual(macCode, victimCode)
        // 2. Même si l'humain clique quand même, la signature du Mac porte sur une autre clé.
        let accept = try computer.confirm(codesMatch: true, now: t0).accept
        assertFails(.invalidSignature) { try victim.finish(accept: accept, codesMatch: true) }
    }

    func testFakeMacCannotFinish() throws {
        let computer = newMac(), phone = try newParent(for: computer)
        let nonce = try computer.makeNonce(request: phone.makeRequest(), now: t0)
        _ = try phone.reveal(nonce: nonce)
        let pairingID = Data(nonce.dropFirst(24).prefix(16))
        let forged = try PairingMath.packet(.pairAccept, body: pairingID + TestSigner().sign(Data()))
        assertFails(.invalidSignature) { try phone.finish(accept: forged, codesMatch: true) }
    }

    // MARK: - Refus et délais

    func testHumanRefusal() throws {
        let computer = newMac(), phone = try newParent(for: computer)
        let nonce = try computer.makeNonce(request: phone.makeRequest(), now: t0)
        let revealed = try phone.reveal(nonce: nonce)
        _ = try computer.verify(reveal: revealed.reveal, now: t0)
        assertFails(.refusedByUser) { try computer.confirm(codesMatch: false, now: t0) }
        // Pas de seconde chance.
        assertFails(.invalidState) { try computer.confirm(codesMatch: true, now: t0) }
        assertFails(.refusedByUser) { try phone.finish(accept: Data(), codesMatch: false) }
    }

    func testEveryMacStepExpires() throws {
        let late = t0.advanced(by: .seconds(120))

        let first = newMac()
        let request = try newParent(for: first).makeRequest()
        assertFails(.expired) { try first.makeNonce(request: request, now: late) }

        let second = newMac(), phone2 = try newParent(for: second)
        let nonce2 = try second.makeNonce(request: phone2.makeRequest(), now: t0)
        let reveal2 = try phone2.reveal(nonce: nonce2).reveal
        assertFails(.expired) { try second.verify(reveal: reveal2, now: late) }

        let third = newMac(), phone3 = try newParent(for: third)
        let nonce3 = try third.makeNonce(request: phone3.makeRequest(), now: t0)
        _ = try third.verify(reveal: phone3.reveal(nonce: nonce3).reveal, now: t0)
        assertFails(.expired) { try third.confirm(codesMatch: true, now: late) }
    }

    func testCancelledFaceIDStopsPairing() throws {
        let computer = newMac()
        let phone = try newParent(for: computer, signer: CancelledSigner(publicKey: parent.publicKey))
        let nonce = try computer.makeNonce(request: phone.makeRequest(), now: t0)
        XCTAssertThrowsError(try phone.reveal(nonce: nonce)) { XCTAssertTrue($0 is CancelledSigner.Cancelled) }
        assertFails(.invalidState) { try phone.reveal(nonce: nonce) }
    }

    func testStepsOutOfOrderAreRejected() throws {
        let computer = newMac()
        assertFails(.invalidState) { try computer.verify(reveal: Data(), now: t0) }
        let other = newMac()
        assertFails(.invalidState) { try other.confirm(codesMatch: true, now: t0) }
        let phone = try newParent(for: newMac())
        assertFails(.invalidState) { try phone.reveal(nonce: Data()) }
        assertFails(.invalidState) { try phone.finish(accept: Data(), codesMatch: true) }
    }
}
