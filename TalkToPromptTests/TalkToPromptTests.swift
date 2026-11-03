import AVFoundation
import XCTest
@testable import TalkToPrompt

final class TalkToPromptTests: XCTestCase {
    func testChordEdgesInEitherPressAndReleaseOrder() {
        for firstIsLeft in [true, false] {
            for releaseLeftFirst in [true, false] {
                var chord = ShiftChordState()
                XCTAssertNil(chord.update(leftPressed: false, rightPressed: false))
                XCTAssertNil(chord.update(leftPressed: firstIsLeft, rightPressed: !firstIsLeft))
                XCTAssertEqual(chord.update(leftPressed: true, rightPressed: true), true)
                XCTAssertNil(chord.update(leftPressed: true, rightPressed: true))
                XCTAssertEqual(chord.update(leftPressed: !releaseLeftFirst, rightPressed: releaseLeftFirst), false)
                XCTAssertNil(chord.update(leftPressed: false, rightPressed: false))
            }
        }
    }

    func testRepressingEitherShiftRearmsTheChord() {
        var chord = ShiftChordState()
        XCTAssertEqual(chord.update(leftPressed: true, rightPressed: true), true)
        XCTAssertEqual(chord.update(leftPressed: false, rightPressed: true), false)
        XCTAssertEqual(chord.update(leftPressed: true, rightPressed: true), true)
        XCTAssertEqual(chord.update(leftPressed: true, rightPressed: false), false)
        XCTAssertEqual(chord.update(leftPressed: true, rightPressed: true), true)
    }

    func testSynchronizingHeldKeysDoesNotInventAnEdge() {
        var chord = ShiftChordState()
        chord.synchronize(leftPressed: true, rightPressed: true)
        XCTAssertNil(chord.update(leftPressed: true, rightPressed: true))
        XCTAssertEqual(chord.update(leftPressed: false, rightPressed: true), false)
    }

    @MainActor
    func testBothTonesAreOneSecondWithExpectedFrequency() throws {
        for tone in BeepPlayer.Tone.allCases {
            let data = BeepPlayer.makeWaveData(frequency: tone.rawValue)
            let player = try AVAudioPlayer(data: data)
            XCTAssertEqual(player.duration, 1, accuracy: 0.000001)
            XCTAssertEqual(player.numberOfChannels, 1)
            XCTAssertEqual(data.count, 44 + 44_100 * 2)
            let samples = data.dropFirst(44).withUnsafeBytes { bytes in
                (0..<44_100).map {
                    Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
                }
            }
            XCTAssertEqual(samples.first, 0)
            XCTAssertEqual(samples.last, 0)
            let crossings = zip(samples, samples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
            XCTAssertEqual(crossings, Int(tone.rawValue))
            XCTAssertLessThanOrEqual(samples.map { abs(Int($0)) }.max()!, 8192)
        }
    }

    @MainActor
    func testStartupExplainsMissingPermissionWithoutRequestingIt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var requests = 0
        let monitor = ShiftMonitor(defaults: defaults, checkPermission: { false }, requestAccess: {
            requests += 1
            return false
        })
        defer { monitor.stop() }
        monitor.start()
        XCTAssertEqual(monitor.status, .needsPermission)
        XCTAssertTrue(monitor.showPermissionExplanation)
        XCTAssertEqual(requests, 0)
        monitor.showPermissionExplanation = false
        monitor.refreshPermission()
        XCTAssertFalse(monitor.showPermissionExplanation)
        XCTAssertEqual(requests, 0)
        monitor.requestPermission()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(monitor.status, .needsPermission)
        XCTAssertFalse(monitor.showPermissionExplanation)
        monitor.stop()
        monitor.start()
        XCTAssertFalse(monitor.showPermissionExplanation)
        XCTAssertEqual(requests, 1)
    }
}
