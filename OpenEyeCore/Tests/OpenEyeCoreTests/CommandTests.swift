import CryptoKit
import XCTest
@testable import OpenEyeCore

/// Commandes Verrouiller / Déverrouiller (docs/protocole.md §6, STRIDE L1–L8).
final class CommandTests: XCTestCase {
    private let t0 = ContinuousClock().now
    private let wall: UInt64 = 1_700_000_000_000
    private let parent = TestSigner()
    private let mac = TestSigner()
    private let sessionID: UInt64 = 0x0102030405060708

    private func issued(_ gate: inout CommandGate) throws -> CommandChallenge {
        try gate.issueChallenge(now: t0)
    }

    private func lock(_ seconds: UInt32, _ challenge: CommandChallenge, signer: any Signer? = nil) throws -> SignedCommand {
        try SignedCommand.make(
            .lock, durationSeconds: seconds, challenge: challenge, sessionID: sessionID, signer: signer ?? parent
        )
    }

    // MARK: - Acceptation

    func testValidLockIsAcceptedOnce() throws {
        var gate = CommandGate()
        let command = try lock(300, try issued(&gate))
        XCTAssertEqual(try gate.accept(command, parent: parent.publicKey, sessionID: sessionID, now: t0), 300)
        // L7 : la même commande rejouée ne trouve plus de défi.
        XCTAssertThrowsError(try gate.accept(command, parent: parent.publicKey, sessionID: sessionID, now: t0)) {
            XCTAssertEqual($0 as? CommandError, .noChallenge)
        }
    }

    func testUnlockHasNoDuration() throws {
        var gate = CommandGate()
        let command = try SignedCommand.make(
            .unlock, durationSeconds: 999, challenge: try issued(&gate), sessionID: sessionID, signer: parent
        )
        XCTAssertEqual(command.durationSeconds, 0)
        XCTAssertEqual(try gate.accept(command, parent: parent.publicKey, sessionID: sessionID, now: t0), 0)
    }

    /// L5 : le plafond est appliqué par le Mac, quelle que soit la durée demandée.
    func testDurationIsCappedByTheMac() throws {
        var gate = CommandGate()
        let command = try lock(.max, try issued(&gate))
        XCTAssertEqual(
            try gate.accept(command, parent: parent.publicKey, sessionID: sessionID, now: t0), Limits.maxLockSeconds
        )
    }

    // MARK: - Refus

    /// L1 : une clé inconnue est refusée.
    func testUnknownKeyIsRefused() throws {
        var gate = CommandGate()
        let command = try lock(60, try issued(&gate), signer: TestSigner())
        XCTAssertThrowsError(try gate.accept(command, parent: parent.publicKey, sessionID: sessionID, now: t0)) {
            XCTAssertEqual($0 as? CommandError, .invalidSignature)
        }
    }

    /// L2 : la durée modifiée casse la signature.
    func testTamperedDurationIsRefused() throws {
        var gate = CommandGate()
        var bytes = [UInt8](try lock(60, try issued(&gate)).payload)
        bytes[35] ^= 0x01
        let tampered = try SignedCommand(.lock, payload: Data(bytes))
        XCTAssertThrowsError(try gate.accept(tampered, parent: parent.publicKey, sessionID: sessionID, now: t0)) {
            XCTAssertEqual($0 as? CommandError, .invalidSignature)
        }
    }

    /// Verrouiller signé, présenté comme Déverrouiller : refusé (durée non nulle) ou signature invalide.
    func testCommandTypeCannotBeSwapped() throws {
        let command = try lock(60, CommandChallenge(nonce: Data(count: 32)))
        XCTAssertThrowsError(try SignedCommand(.unlock, payload: command.payload))
        let unlock = try SignedCommand.make(
            .unlock, durationSeconds: 0, challenge: CommandChallenge(nonce: Data(count: 32)),
            sessionID: sessionID, signer: parent
        )
        var bytes = [UInt8](unlock.payload)
        bytes[35] = 60
        let swapped = try SignedCommand(.lock, payload: Data(bytes))
        XCTAssertFalse(swapped.isSigned(by: parent.publicKey, sessionID: sessionID))
    }

    /// L7 : une commande d'une autre session ne vaut rien ici.
    func testCommandFromAnotherSessionIsRefused() throws {
        var gate = CommandGate()
        let command = try lock(60, try issued(&gate))
        XCTAssertThrowsError(try gate.accept(command, parent: parent.publicKey, sessionID: sessionID + 1, now: t0)) {
            XCTAssertEqual($0 as? CommandError, .invalidSignature)
        }
    }

    func testCommandWithoutChallengeIsRefused() throws {
        var gate = CommandGate()
        let command = try lock(60, CommandChallenge(nonce: Data(count: 32)))
        XCTAssertThrowsError(try gate.accept(command, parent: parent.publicKey, sessionID: sessionID, now: t0)) {
            XCTAssertEqual($0 as? CommandError, .noChallenge)
        }
    }

    func testOldChallengeIsRefused() throws {
        var gate = CommandGate()
        let old = try issued(&gate)
        _ = try gate.issueChallenge(now: t0.advanced(by: Limits.minCommandInterval))
        XCTAssertThrowsError(try gate.accept(
            try lock(60, old), parent: parent.publicKey, sessionID: sessionID, now: t0.advanced(by: .seconds(3))
        )) {
            XCTAssertEqual($0 as? CommandError, .challengeMismatch)
        }
    }

    func testExpiredChallengeIsRefusedAndConsumed() throws {
        var gate = CommandGate()
        let command = try lock(60, try issued(&gate))
        let late = t0.advanced(by: Limits.commandChallengeLifetime)
        XCTAssertThrowsError(try gate.accept(command, parent: parent.publicKey, sessionID: sessionID, now: late)) {
            XCTAssertEqual($0 as? CommandError, .challengeExpired)
        }
        XCTAssertThrowsError(try gate.accept(command, parent: parent.publicKey, sessionID: sessionID, now: t0)) {
            XCTAssertEqual($0 as? CommandError, .noChallenge)
        }
    }

    /// Un mauvais essai consomme le défi : pas de seconde chance sur le même nC.
    func testFailedAttemptConsumesChallenge() throws {
        var gate = CommandGate()
        let challenge = try issued(&gate)
        XCTAssertThrowsError(try gate.accept(
            try lock(60, challenge, signer: TestSigner()), parent: parent.publicKey, sessionID: sessionID, now: t0
        ))
        XCTAssertThrowsError(try gate.accept(
            try lock(60, challenge), parent: parent.publicKey, sessionID: sessionID, now: t0
        )) {
            XCTAssertEqual($0 as? CommandError, .noChallenge)
        }
    }

    /// L6 : une rafale de demandes ne produit qu'un défi.
    func testChallengeRequestsAreRateLimited() throws {
        var gate = CommandGate()
        _ = try issued(&gate)
        XCTAssertThrowsError(try gate.issueChallenge(now: t0.advanced(by: .seconds(1)))) {
            XCTAssertEqual($0 as? CommandError, .tooSoon)
        }
        XCTAssertNoThrow(try gate.issueChallenge(now: t0.advanced(by: Limits.minCommandInterval)))
    }

    /// L8 : Face ID annulé, aucune commande n'est produite.
    func testCancelledFaceIDProducesNoCommand() throws {
        var gate = CommandGate()
        XCTAssertThrowsError(try lock(60, try issued(&gate), signer: CancelledSigner(publicKey: parent.publicKey)))
    }

    func testMalformedPayloadsAreRefused() throws {
        XCTAssertThrowsError(try SignedCommand(.lock, payload: Data(count: 99)))
        XCTAssertThrowsError(try SignedCommand(.lock, payload: Data(count: 100))) // durée nulle
        XCTAssertThrowsError(try CommandChallenge(payload: Data(count: 31)))
        XCTAssertThrowsError(try CommandResult(payload: Data([3]) + Data(count: 8)))
        XCTAssertEqual(try CommandResult(payload: CommandResult(status: .locked, endsAt: wall).payload),
                       CommandResult(status: .locked, endsAt: wall))
    }

    // MARK: - Journal (L3)

    func testJournalVerifiesParentSignatureOfCommands() throws {
        var gate = CommandGate()
        let command = try lock(300, try issued(&gate))
        var chain = JournalChain()
        try chain.append(.paired, data: JournalData.paired(parent: parent.publicKey), timestamp: wall, signer: mac)
        try chain.append(.lock, data: JournalData.command(command, sessionID: sessionID), timestamp: wall, signer: mac)
        XCTAssertEqual(JournalChain.verify(chain.entries, macIdentity: mac.publicKey), .valid(entries: 2))

        let decoded = try JournalChain(encoded: chain.encoded)
        XCTAssertEqual(decoded.entries, chain.entries)
    }

    /// Même signée par le Mac, une commande que le parent n'a pas signée est détectée.
    func testJournalDetectsForgedCommand() throws {
        var gate = CommandGate()
        let forged = try lock(300, try issued(&gate), signer: TestSigner())
        var chain = JournalChain()
        try chain.append(.paired, data: JournalData.paired(parent: parent.publicKey), timestamp: wall, signer: mac)
        try chain.append(.lock, data: JournalData.command(forged, sessionID: sessionID), timestamp: wall, signer: mac)
        XCTAssertEqual(JournalChain.verify(chain.entries, macIdentity: mac.publicKey), .altered(position: 2))
    }

    func testJournalRefusesCommandWithoutPairedParent() throws {
        var gate = CommandGate()
        let command = try lock(300, try issued(&gate))
        var chain = JournalChain()
        try chain.append(.lock, data: JournalData.command(command, sessionID: sessionID), timestamp: wall, signer: mac)
        XCTAssertEqual(JournalChain.verify(chain.entries, macIdentity: mac.publicKey), .altered(position: 1))
    }

    // MARK: - Sur le canal chiffré

    func testCommandFramesOnlyTravelInTheRightDirection() throws {
        for type in [FrameType.lock, .unlock, .cmdChallengeRequest] {
            XCTAssertTrue(type.canBeSent(by: .iphone))
            XCTAssertFalse(type.canBeSent(by: .mac))
        }
        for type in [FrameType.cmdChallenge, .cmdResult] {
            XCTAssertTrue(type.canBeSent(by: .mac))
            XCTAssertFalse(type.canBeSent(by: .iphone))
        }
    }

    /// Parcours complet : demande, défi, commande signée, résultat, à travers les deux canaux.
    func testFullLockJourneyOverChannels() throws {
        let phoneHandshake = ParentHandshake(parent: parent, macIdentity: mac.publicKey)
        let macHandshake = MacHandshake(mac: mac, parentIdentity: parent.publicKey)
        let challengePacket = try macHandshake.makeChallenge(hello: try phoneHandshake.makeHello(), now: t0)
        let answer = try phoneHandshake.answer(challenge: challengePacket, now: { self.t0 })
        let phone = answer.channel
        let computer = try macHandshake.accept(auth: answer.auth, now: t0).channel

        var gate = CommandGate()
        let request = try phone.seal(.cmdChallengeRequest, timestamp: wall, now: t0)
        _ = try computer.open(request, allowed: [.cmdChallengeRequest], wallClock: wall, now: t0)
        let challengeFrame = try computer.seal(.cmdChallenge, payload: try issued(&gate).payload, timestamp: wall, now: t0)
        let challenge = try CommandChallenge(
            payload: try phone.open(challengeFrame, allowed: [.cmdChallenge], wallClock: wall, now: t0).payload
        )

        let command = try SignedCommand.make(
            .lock, durationSeconds: 600, challenge: challenge, sessionID: phone.sessionID, signer: parent
        )
        let lockFrame = try phone.seal(.lock, payload: command.payload, timestamp: wall, now: t0)
        let received = try computer.open(lockFrame, allowed: [.lock, .unlock], wallClock: wall, now: t0)
        let parsed = try SignedCommand(.lock, payload: received.payload)
        XCTAssertEqual(
            try gate.accept(parsed, parent: parent.publicKey, sessionID: computer.sessionID, now: t0), 600
        )

        let result = try computer.seal(
            .cmdResult, payload: CommandResult(status: .locked, endsAt: wall + 600_000).payload,
            timestamp: wall, now: t0
        )
        let reply = try phone.open(result, allowed: [.cmdResult], wallClock: wall, now: t0)
        XCTAssertEqual(try CommandResult(payload: reply.payload).status, .locked)
    }
}
