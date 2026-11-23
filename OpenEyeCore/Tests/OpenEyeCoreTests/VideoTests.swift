import XCTest
@testable import OpenEyeCore

final class VideoTests: XCTestCase {
    private let t0 = ContinuousClock().now

    /// Image factice : octets dérivés de leur position, aucune vraie capture.
    private func fakeFrame(_ size: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        for position in 0..<size {
            let value: Int = position * 31 + position / 256
            bytes[position] = UInt8(truncatingIfNeeded: value)
        }
        return Data(bytes)
    }

    private func fragment(_ id: UInt32, _ index: Int = 0, of count: Int = 1, key: Bool = true, size: Int = 4) -> Data {
        VideoFragment(frameID: id, index: index, count: count, isKeyFrame: key, data: Data(count: size)).payload
    }

    // MARK: - Découpage

    func testSplitAndAssembleAtEveryBoundary() throws {
        let part = Limits.maxFragmentData
        for size in [1, part - 1, part, part + 1, 3 * part, Limits.maxFrameSize] {
            var splitter = FrameSplitter(), assembler = FrameAssembler()
            let frame = fakeFrame(size)
            let payloads = try splitter.split(frame, isKeyFrame: true)
            XCTAssertLessThanOrEqual(payloads.count, Limits.maxFragmentsPerFrame)
            var result: VideoFrame?
            for (index, payload) in payloads.enumerated() {
                result = try assembler.add(payload, now: t0)
                XCTAssertEqual(result != nil, index == payloads.count - 1)
            }
            XCTAssertEqual(result, VideoFrame(id: 1, isKeyFrame: true, data: frame))
            XCTAssertEqual(assembler.pendingBytes, 0, "rien n'est conservé après la sortie")
        }
    }

    func testEveryFragmentFitsInAPacket() throws {
        var splitter = FrameSplitter()
        for payload in try splitter.split(fakeFrame(Limits.maxFrameSize), isKeyFrame: true) {
            XCTAssertTrue(FrameType.videoFragment.bodySize.contains(8 + payload.count))
        }
    }

    func testSplitterRefusesEmptyAndHugeFrames() {
        var splitter = FrameSplitter()
        XCTAssertThrowsError(try splitter.split(Data(), isKeyFrame: true))
        XCTAssertThrowsError(try splitter.split(Data(count: Limits.maxFrameSize + 1), isKeyFrame: true))
    }

    // MARK: - Fragments hostiles

    func testMalformedFragmentsAreRejected() {
        var assembler = FrameAssembler()
        let invalid = [
            Data(), Data(count: 9), // pas de données
            fragment(0), // numéro réservé
            fragment(1, 0, of: 0), // aucun fragment annoncé
            fragment(1, 1, of: 1), // indice hors bornes
            fragment(1, 0, of: Limits.maxFragmentsPerFrame + 1),
            fragment(1, 65_535, of: 65_535),
            fragment(1, size: Limits.maxFragmentData + 1),
        ]
        for payload in invalid {
            XCTAssertThrowsError(try assembler.add(payload, now: t0)) {
                XCTAssertEqual($0 as? VideoError, .invalidFragment)
            }
        }
        var unknownFlag = fragment(1)
        unknownFlag[8] = 2
        XCTAssertThrowsError(try assembler.add(unknownFlag, now: t0))
        XCTAssertEqual(assembler.pendingCount, 0)
    }

    func testDuplicateOrInconsistentFragmentDropsTheFrame() throws {
        let second = [
            fragment(1, 0, of: 3), // doublon
            fragment(1, 1, of: 4), // nombre différent
            fragment(1, 1, of: 3, key: false), // drapeau différent
        ]
        for payload in second {
            var assembler = FrameAssembler()
            XCTAssertNil(try assembler.add(fragment(1, 0, of: 3), now: t0))
            XCTAssertThrowsError(try assembler.add(payload, now: t0)) {
                XCTAssertEqual($0 as? VideoError, .inconsistentFragment)
            }
            XCTAssertEqual(assembler.pendingCount, 0)
            // La suite de l'image jetée est ignorée.
            XCTAssertNil(try assembler.add(fragment(1, 1, of: 3), now: t0))
            XCTAssertEqual(assembler.pendingCount, 0)
        }
    }

    // MARK: - Mémoire bornée

    func testOrphanFragmentsNeverExceedTheLimit() throws {
        var assembler = FrameAssembler()
        for id in UInt32(1)...1_000 {
            XCTAssertNil(try assembler.add(fragment(id, 0, of: 64, size: Limits.maxFragmentData), now: t0))
            XCTAssertLessThanOrEqual(assembler.pendingCount, Limits.maxPendingFrames)
        }
        XCTAssertLessThanOrEqual(assembler.pendingBytes, Limits.maxPendingFrames * Limits.maxFrameSize)
    }

    func testIncompleteFrameIsPurgedAfterOneSecond() throws {
        var assembler = FrameAssembler()
        XCTAssertNil(try assembler.add(fragment(1, 0, of: 2), now: t0))
        assembler.purge(now: t0.advanced(by: .milliseconds(999)))
        XCTAssertEqual(assembler.pendingCount, 1)
        assembler.purge(now: t0.advanced(by: .seconds(1)))
        XCTAssertEqual(assembler.pendingCount, 0)
        XCTAssertNil(try assembler.add(fragment(1, 1, of: 2), now: t0.advanced(by: .seconds(1))))
    }

    func testResetForgetsEverything() throws {
        var assembler = FrameAssembler()
        _ = try assembler.add(fragment(1, 0, of: 2), now: t0)
        assembler.reset()
        XCTAssertEqual(assembler.pendingBytes, 0)
    }

    func testExtremeFrameIDsDoNotCrash() throws {
        var assembler = FrameAssembler()
        XCTAssertNotNil(try assembler.add(fragment(.max), now: t0))
        XCTAssertNil(try assembler.add(fragment(1, key: false), now: t0))
        XCTAssertNil(try assembler.add(fragment(.max, key: false), now: t0))
    }

    // MARK: - Images décodables seulement

    func testWaitsForAKeyFrameAtStart() throws {
        var assembler = FrameAssembler()
        XCTAssertNil(try assembler.add(fragment(1, key: false), now: t0))
        XCTAssertNotNil(try assembler.add(fragment(2, key: true), now: t0))
        XCTAssertNotNil(try assembler.add(fragment(3, key: false), now: t0))
    }

    func testWaitsForAKeyFrameAfterALoss() throws {
        var assembler = FrameAssembler()
        XCTAssertNotNil(try assembler.add(fragment(1), now: t0))
        // L'image 2 est perdue.
        XCTAssertNil(try assembler.add(fragment(3, key: false), now: t0))
        XCTAssertNil(try assembler.add(fragment(4, key: false), now: t0))
        XCTAssertNotNil(try assembler.add(fragment(5, key: true), now: t0))
        XCTAssertNotNil(try assembler.add(fragment(6, key: false), now: t0))
    }

    // MARK: - VideoParams

    func testParamsRoundTrip() throws {
        let params = try VideoParams(width: 960, height: 600, sps: fakeFrame(30), pps: fakeFrame(5))
        XCTAssertEqual(try VideoParams(payload: params.payload), params)
        XCTAssertTrue(FrameType.videoParams.bodySize.contains(8 + params.payload.count))
    }

    func testParamsLimits() throws {
        let one = Data([1])
        for (width, height) in [(0, 600), (960, 0), (961, 600), (960, 601), (4_098, 600), (960, 4_098), (-2, 600)] {
            XCTAssertThrowsError(try VideoParams(width: width, height: height, sps: one, pps: one))
        }
        XCTAssertThrowsError(try VideoParams(width: 960, height: 600, sps: Data(), pps: one))
        XCTAssertThrowsError(try VideoParams(width: 960, height: 600, sps: one, pps: Data()))
        // 1 008 octets au total pour SPS et PPS.
        XCTAssertNoThrow(try VideoParams(width: 960, height: 600, sps: Data(count: 1_000), pps: Data(count: 8)))
        XCTAssertThrowsError(try VideoParams(width: 960, height: 600, sps: Data(count: 1_000), pps: Data(count: 9)))
    }

    /// Toute troncature ou tout octet en trop est refusé, ainsi que des longueurs mensongères.
    func testMalformedParamsAreRejected() throws {
        let payload = try VideoParams(width: 960, height: 600, sps: fakeFrame(30), pps: fakeFrame(5)).payload
        for size in 0..<payload.count {
            XCTAssertThrowsError(try VideoParams(payload: payload.prefix(size)))
        }
        XCTAssertThrowsError(try VideoParams(payload: payload + Data([0])))
        for index in [4, 36] { // octets de poids fort des deux longueurs
            var lying = payload
            lying[index] = 0xFF
            XCTAssertThrowsError(try VideoParams(payload: lying))
        }
    }
}
