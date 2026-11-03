import AVFoundation
import XCTest
@testable import TalkToPrompt

final class TalkToPromptTests: XCTestCase {
    @MainActor
    func testAccessibilitySettingsReturnOffersOneRestartEvenWithCachedDenial() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var openedPanes: [String] = []
        let monitor = ShiftMonitor(
            defaults: defaults, checkPermission: { false }, requestAccess: { false },
            checkEventPostingPermission: { false }, requestEventPostingAccess: { false },
            openSettings: { openedPanes.append($0) },
            frontmostBundleIdentifier: { Bundle.main.bundleIdentifier }
        )
        defer { monitor.stop() }
        monitor.start()
        monitor.openAccessibilitySettings()
        XCTAssertEqual(openedPanes, ["Privacy_Accessibility"])
        XCTAssertFalse(monitor.showRestartConfirmation)
        monitor.applicationActivated(bundleIdentifier: "com.apple.systempreferences")
        monitor.applicationActivated(bundleIdentifier: Bundle.main.bundleIdentifier)
        XCTAssertTrue(monitor.showRestartConfirmation)
        XCTAssertFalse(monitor.hasEventPostingPermission)
        monitor.showRestartConfirmation = false
        monitor.applicationActivated(bundleIdentifier: Bundle.main.bundleIdentifier)
        monitor.refreshPermission()
        XCTAssertFalse(monitor.showRestartConfirmation)
    }

    @MainActor
    func testAlreadyGrantedAccessibilityDoesNotRequestAnotherRestart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let monitor = ShiftMonitor(
            defaults: defaults, checkPermission: { false }, requestAccess: { false },
            checkEventPostingPermission: { true },
            requestEventPostingAccess: { XCTFail("Already granted"); return true },
            openSettings: { _ in }, frontmostBundleIdentifier: { Bundle.main.bundleIdentifier }
        )
        defer { monitor.stop() }
        monitor.start()
        monitor.openAccessibilitySettings()
        monitor.applicationActivated(bundleIdentifier: "com.apple.systempreferences")
        monitor.applicationActivated(bundleIdentifier: Bundle.main.bundleIdentifier)
        XCTAssertFalse(monitor.showRestartConfirmation)
    }

    @MainActor
    func testRestartLaunchesReplacementBeforeQuittingAndDoesNotRepeat() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var actions: [String] = []
        let monitor = ShiftMonitor(
            defaults: defaults, checkPermission: { false }, requestAccess: { false },
            checkEventPostingPermission: { false }, requestEventPostingAccess: { false },
            launchNewInstance: { actions.append("launch") },
            terminateCurrentInstance: { actions.append("quit") }
        )
        defer { monitor.stop() }
        monitor.start()
        await monitor.restart()
        await monitor.restart()
        XCTAssertEqual(actions, ["launch", "quit"])
        XCTAssertTrue(monitor.isRestarting)
        XCTAssertEqual(monitor.status, .checking)
    }

    @MainActor
    func testFailedRestartKeepsCurrentAppRunningAndReportsError() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let monitor = ShiftMonitor(
            defaults: defaults, checkPermission: { false }, requestAccess: { false },
            checkEventPostingPermission: { false }, requestEventPostingAccess: { false },
            launchNewInstance: { throw NSError(domain: "RestartTest", code: 1) },
            terminateCurrentInstance: { XCTFail("Must not quit if launching fails") }
        )
        defer { monitor.stop() }
        monitor.start()
        await monitor.restart()
        XCTAssertFalse(monitor.isRestarting)
        XCTAssertNotNil(monitor.restartError)
        XCTAssertEqual(monitor.status, .needsPermission)
    }

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
        let monitor = ShiftMonitor(
            defaults: defaults,
            checkPermission: { false },
            requestAccess: {
                requests += 1
                return false
            },
            checkEventPostingPermission: { true },
            requestEventPostingAccess: { XCTFail("Posting permission is already granted"); return true }
        )
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

    @MainActor
    func testMissingPermissionsAreRequestedIndependentlyWithoutRepeatedPrompts() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var inputRequests = 0
        var postingRequests = 0
        let monitor = ShiftMonitor(
            defaults: defaults,
            checkPermission: { false },
            requestAccess: { inputRequests += 1; return false },
            checkEventPostingPermission: { false },
            requestEventPostingAccess: { postingRequests += 1; return false }
        )
        defer { monitor.stop() }
        monitor.start()
        XCTAssertTrue(monitor.showPermissionExplanation)
        XCTAssertFalse(monitor.hasEventPostingPermission)
        XCTAssertEqual(inputRequests, 0)
        XCTAssertEqual(postingRequests, 0)

        monitor.requestEventPostingPermission()
        XCTAssertEqual(postingRequests, 1)
        XCTAssertEqual(inputRequests, 0)
        XCTAssertEqual(monitor.status, .needsPermission)
        XCTAssertFalse(monitor.showPermissionExplanation)
        monitor.refreshPermission()
        XCTAssertFalse(monitor.showPermissionExplanation)
        XCTAssertEqual(postingRequests, 1)

        monitor.requestPermission()
        XCTAssertEqual(inputRequests, 1)
        XCTAssertEqual(postingRequests, 1)
        monitor.stop()
        monitor.start()
        XCTAssertFalse(monitor.showPermissionExplanation)
        XCTAssertEqual(inputRequests, 1)
        XCTAssertEqual(postingRequests, 1)
    }

    @MainActor
    func testPostingPermissionGrantAndRevocationAreRechecked() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var postingGranted = false
        let monitor = ShiftMonitor(
            defaults: defaults,
            checkPermission: { false },
            requestAccess: { XCTFail("Input permission should not be requested"); return false },
            checkEventPostingPermission: { postingGranted },
            requestEventPostingAccess: { postingGranted = true; return true }
        )
        defer { monitor.stop() }
        monitor.start()
        monitor.requestEventPostingPermission()
        XCTAssertTrue(monitor.hasEventPostingPermission)
        XCTAssertEqual(monitor.status, .needsPermission)
        postingGranted = false
        monitor.refreshPermission()
        XCTAssertFalse(monitor.hasEventPostingPermission)
        XCTAssertEqual(monitor.status, .needsPermission)
        XCTAssertFalse(monitor.showPermissionExplanation)
    }
}
