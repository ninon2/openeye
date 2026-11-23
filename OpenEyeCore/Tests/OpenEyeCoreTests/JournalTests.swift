import CryptoKit
import XCTest
@testable import OpenEyeCore

final class JournalTests: XCTestCase {
    private let mac = TestSigner()
    private let parent = TestSigner()
    private let day: UInt64 = 24 * 3_600 * 1_000
    private let t0: UInt64 = 1_700_000_000_000

    /// Preuve de session réelle, produite par un handshake complet.
    private func sessionOpenedData() throws -> Data {
        let iPhone = ParentHandshake(parent: parent, macIdentity: mac.publicKey)
        let computer = MacHandshake(mac: mac, parentIdentity: parent.publicKey)
        let now = ContinuousClock().now
        let challenge = try computer.makeChallenge(hello: iPhone.makeHello(), now: now)
        let session = try computer.accept(auth: iPhone.answer(challenge: challenge, now: { now }).auth, now: now)
        return JournalData.sessionOpened(
            sessionID: session.channel.sessionID, transcriptHash: session.transcriptHash,
            parentSignature: session.parentSignature
        )
    }

    private func sampleJournal() throws -> JournalChain {
        var journal = JournalChain()
        try journal.append(.appStarted, timestamp: t0, signer: mac)
        try journal.append(.paired, data: JournalData.paired(parent: parent.publicKey), timestamp: t0 + 1, signer: mac)
        try journal.append(.sessionOpened, data: sessionOpenedData(), timestamp: t0 + 2, signer: mac)
        try journal.append(.captureStarted, data: JournalData.capture(sessionID: 7), timestamp: t0 + 3, signer: mac)
        try journal.append(.captureStopped, data: JournalData.capture(sessionID: 7), timestamp: t0 + 4, signer: mac)
        try journal.append(
            .sessionClosed, data: JournalData.sessionClosed(sessionID: 7, reason: .userStop),
            timestamp: t0 + 5, signer: mac
        )
        return journal
    }

    // MARK: - Réussite

    func testLegitimateJournalIsValidAfterRoundTrip() throws {
        let journal = try sampleJournal()
        let reloaded = try JournalChain(encoded: journal.encoded)
        XCTAssertEqual(reloaded.entries, journal.entries)
        XCTAssertEqual(JournalChain.verify(reloaded.entries, macIdentity: mac.publicKey), .valid(entries: 6))
        XCTAssertEqual(reloaded.head.seq, 6)
        XCTAssertEqual(reloaded.head.hash, journal.entries.last?.hash)
    }

    func testEmptyJournalHasZeroHead() {
        let journal = JournalChain()
        XCTAssertEqual(journal.head.seq, 0)
        XCTAssertEqual(journal.head.hash, Data(count: 32))
    }

    // MARK: - Altérations (T4, R1, R2)

    func testModifiedEntryIsDetected() throws {
        var bytes = [UInt8](try sampleJournal().encoded)
        // Le timestamp de la première entrée.
        bytes[10] ^= 0x01
        let journal = try JournalChain(encoded: Data(bytes))
        XCTAssertEqual(JournalChain.verify(journal.entries, macIdentity: mac.publicKey), .altered(position: 1))
    }

    func testDeletedMiddleEntryIsDetected() throws {
        var entries = try sampleJournal().entries
        entries.remove(at: 2)
        XCTAssertEqual(JournalChain.verify(entries, macIdentity: mac.publicKey), .altered(position: 3))
    }

    func testReorderedEntriesAreDetected() throws {
        var entries = try sampleJournal().entries
        entries.swapAt(3, 4)
        XCTAssertEqual(JournalChain.verify(entries, macIdentity: mac.publicKey), .altered(position: 4))
    }

    func testOtherMacKeyIsRejected() throws {
        let entries = try sampleJournal().entries
        XCTAssertEqual(JournalChain.verify(entries, macIdentity: TestSigner().publicKey), .altered(position: 1))
    }

    func testForgedSessionWithoutParentProofIsDetected() throws {
        // Le Mac (ou l'enfant qui détient sa clé) invente « le parent a regardé » : sigP est impossible à produire.
        var journal = JournalChain()
        try journal.append(.paired, data: JournalData.paired(parent: parent.publicKey), timestamp: t0, signer: mac)
        let forged = JournalData.sessionOpened(
            sessionID: 1, transcriptHash: Data(count: 32), parentSignature: Data(count: 64)
        )
        try journal.append(.sessionOpened, data: forged, timestamp: t0 + 1, signer: mac)
        XCTAssertEqual(JournalChain.verify(journal.entries, macIdentity: mac.publicKey), .altered(position: 2))
    }

    func testSessionAfterRevocationIsDetected() throws {
        var journal = JournalChain()
        try journal.append(.paired, data: JournalData.paired(parent: parent.publicKey), timestamp: t0, signer: mac)
        try journal.append(.revoked, data: JournalData.revoked(parent: parent.publicKey), timestamp: t0 + 1, signer: mac)
        try journal.append(.sessionOpened, data: sessionOpenedData(), timestamp: t0 + 2, signer: mac)
        XCTAssertEqual(JournalChain.verify(journal.entries, macIdentity: mac.publicKey), .altered(position: 3))
    }

    func testTruncatedFileIsMalformed() throws {
        let bytes = try sampleJournal().encoded
        XCTAssertThrowsError(try JournalChain(encoded: bytes.dropLast(10))) {
            XCTAssertEqual($0 as? JournalError, .malformed(position: 6))
        }
    }

    func testWrongDataSizeIsRefused() {
        var journal = JournalChain()
        XCTAssertThrowsError(try journal.append(.revoked, data: Data(count: 31), timestamp: t0, signer: mac)) {
            XCTAssertEqual($0 as? JournalError, .badData)
        }
    }

    // MARK: - Purge et ancre

    func testPurgeKeepsChainVerifiableAndParentKey() throws {
        var journal = JournalChain()
        try journal.append(.paired, data: JournalData.paired(parent: parent.publicKey), timestamp: t0, signer: mac)
        try journal.append(.appStarted, timestamp: t0 + 1, signer: mac)
        try journal.append(.sessionOpened, data: sessionOpenedData(), timestamp: t0 + 40 * day, signer: mac)

        try journal.purge(now: t0 + 41 * day, signer: mac)
        XCTAssertEqual(journal.entries.map(\.event), [.sessionOpened, .purgeCheckpoint])
        // La preuve du parent reste vérifiable alors que PAIRED a disparu (R1).
        XCTAssertEqual(JournalChain.verify(journal.entries, macIdentity: mac.publicKey), .valid(entries: 2))
        XCTAssertEqual(journal.anchorProof(seq: 1).status, .purged)
        XCTAssertEqual(journal.anchorProof(seq: 3).hash, journal.entries.first?.hash)
    }

    func testPurgeOfEverythingStillVerifies() throws {
        var journal = try sampleJournal()
        try journal.purge(now: t0 + 31 * day, signer: mac)
        XCTAssertEqual(journal.entries.map(\.event), [.purgeCheckpoint])
        XCTAssertEqual(journal.entries.first?.seq, 7)
        XCTAssertEqual(JournalChain.verify(journal.entries, macIdentity: mac.publicKey), .valid(entries: 1))
    }

    func testAnchorBeyondHeadNeverMatches() throws {
        let journal = try sampleJournal()
        let proof = journal.anchorProof(seq: 99)
        XCTAssertEqual(proof.status, .present)
        XCTAssertEqual(proof.hash, Data(count: 32))
    }

    func testAnchorVerdicts() {
        let anchor = JournalAnchor(seq: 5, hash: Data(repeating: 7, count: 32), receivedAt: t0)
        let same = JournalAnchorProof(seq: 5, status: .present, hash: anchor.hash)
        let other = JournalAnchorProof(seq: 5, status: .present, hash: Data(count: 32))
        let purged = JournalAnchorProof(seq: 5, status: .purged, hash: Data(count: 32))

        XCTAssertEqual(AnchorCheck.evaluate(anchor: anchor, proof: same, now: t0 + 1), .consistent)
        XCTAssertEqual(AnchorCheck.evaluate(anchor: anchor, proof: other, now: t0 + 1), .altered)
        // Horloge du Mac avancée : purge « normale » impossible avant 29 jours.
        XCTAssertEqual(AnchorCheck.evaluate(anchor: anchor, proof: purged, now: t0 + 2 * day), .altered)
        XCTAssertEqual(AnchorCheck.evaluate(anchor: anchor, proof: purged, now: t0 + 29 * day), .purgedNormally)
        XCTAssertEqual(AnchorCheck.evaluate(anchor: anchor, proof: purged, now: t0 - 1), .impossibleClockChanged)
        XCTAssertTrue(AnchorCheck.headIsBehind(
            anchor: anchor, heartbeat: Heartbeat(captureState: .running, journalSeq: 4, journalHead: Data(count: 32))
        ))
    }

    // MARK: - Messages de session

    func testSessionMessagesRoundTripAndRejectBadSizes() throws {
        let heartbeat = Heartbeat(captureState: .running, journalSeq: 42, journalHead: Data(repeating: 1, count: 32))
        XCTAssertEqual(try Heartbeat(payload: heartbeat.payload), heartbeat)
        XCTAssertThrowsError(try Heartbeat(payload: heartbeat.payload.dropLast()))
        XCTAssertThrowsError(try Heartbeat(payload: Data([9]) + heartbeat.payload.dropFirst()))

        XCTAssertEqual(try CloseMessage(payload: CloseMessage(reason: .background).payload).reason, .background)
        XCTAssertEqual(try CloseMessage(payload: Data([200])).reason, .error)

        let request = JournalAnchorRequest(seq: 9)
        XCTAssertEqual(try JournalAnchorRequest(payload: request.payload), request)

        let proof = JournalAnchorProof(seq: 9, status: .purged, hash: Data(count: 32))
        XCTAssertEqual(try JournalAnchorProof(payload: proof.payload), proof)
        var badStatus = [UInt8](proof.payload)
        badStatus[8] = 2
        XCTAssertThrowsError(try JournalAnchorProof(payload: Data(badStatus)))
    }

    func testSealedMessagesFitDeclaredBodySizes() throws {
        // Chaque corps construit par les apps doit passer la borne exacte de FrameType.bodySize.
        let heartbeat = Heartbeat(captureState: .stopped, journalSeq: 0, journalHead: Data(count: 32))
        XCTAssertTrue(FrameType.heartbeat.bodySize.contains(8 + heartbeat.payload.count))
        XCTAssertTrue(FrameType.close.bodySize.contains(8 + CloseMessage(reason: .userStop).payload.count))
        XCTAssertTrue(FrameType.journalAnchorRequest.bodySize.contains(8 + JournalAnchorRequest(seq: 1).payload.count))
        let proof = JournalAnchorProof(seq: 1, status: .present, hash: Data(count: 32))
        XCTAssertTrue(FrameType.journalAnchorProof.bodySize.contains(8 + proof.payload.count))
    }
}
