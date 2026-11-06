import AppKit
import AVFoundation
import XCTest
@testable import TalkToPrompt

@MainActor
private final class TrayPopoverSpy: NSPopover {
    var simulatedVisibility = true
    var closeRequests = 0
    override var isShown: Bool { simulatedVisibility }
    override func performClose(_ sender: Any?) {
        closeRequests += 1
        simulatedVisibility = false
    }
}

final class TalkToPromptTests: XCTestCase {
    @MainActor
    func testTrayClosesOnAppDeactivationAfterChangingLanguage() {
        let popover = TrayPopoverSpy()
        let delegate = MenuBarAppDelegate(popover: popover)
        let previousLanguage = delegate.monitor.preferredTranscriptionLanguage
        defer { delegate.monitor.preferredTranscriptionLanguage = previousLanguage }
        delegate.monitor.preferredTranscriptionLanguage = "uk"
        delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        XCTAssertEqual(popover.closeRequests, 1)
        XCTAssertFalse(popover.isShown)
        delegate.dismissPopoverForOutsideInteraction()
        XCTAssertEqual(popover.closeRequests, 1)
    }

    @MainActor
    func testOutsideClickClosesTrayButKeepsModalDialogsOpen() {
        let popover = TrayPopoverSpy()
        let delegate = MenuBarAppDelegate(popover: popover)
        delegate.setShowingModal(false)
        XCTAssertEqual(popover.closeRequests, 0, "Initial modal state must not dismiss a newly opening popover")
        delegate.setShowingModal(true)
        XCTAssertEqual(popover.behavior, .applicationDefined)
        XCTAssertFalse(delegate.popoverShouldClose(popover))
        delegate.dismissPopoverForOutsideInteraction()
        delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        XCTAssertEqual(popover.closeRequests, 0)
        delegate.setShowingModal(false)
        XCTAssertEqual(popover.behavior, .transient)
        XCTAssertTrue(delegate.popoverShouldClose(popover))
        delegate.dismissPopoverForOutsideInteraction()
        XCTAssertEqual(popover.closeRequests, 1)
    }

    @MainActor
    func testTranscriptionLanguagePreferencePersistsAndAutoClearsIt() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = ShiftMonitor(defaults: defaults)
        XCTAssertEqual(monitor.preferredTranscriptionLanguage, "")
        monitor.preferredTranscriptionLanguage = "uk"
        XCTAssertEqual(ShiftMonitor(defaults: defaults).preferredTranscriptionLanguage, "uk")
        monitor.preferredTranscriptionLanguage = ""
        XCTAssertNil(defaults.string(forKey: TranscriptionLanguage.preferenceKey))
        XCTAssertEqual(ShiftMonitor(defaults: defaults).preferredTranscriptionLanguage, "")
        defaults.set("invalid-code", forKey: TranscriptionLanguage.preferenceKey)
        XCTAssertEqual(ShiftMonitor(defaults: defaults).preferredTranscriptionLanguage, "")
    }

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
    func testInputMonitoringSettingsReturnOffersRestartWithCachedDenial() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let monitor = ShiftMonitor(defaults: defaults, checkPermission: { false }, requestAccess: { false },
                                   checkEventPostingPermission: { false }, requestEventPostingAccess: { false },
                                   openSettings: { _ in }, frontmostBundleIdentifier: { Bundle.main.bundleIdentifier })
        defer { monitor.stop() }
        monitor.start(showPermissionExplanation: false)
        XCTAssertFalse(monitor.showPermissionExplanation)
        monitor.openInputMonitoringSettings()
        monitor.applicationActivated(bundleIdentifier: "com.apple.systempreferences")
        monitor.applicationActivated(bundleIdentifier: Bundle.main.bundleIdentifier)
        XCTAssertTrue(monitor.showRestartConfirmation)
        XCTAssertEqual(monitor.restartPermissionName, "Input Monitoring")
        monitor.showRestartConfirmation = false
        monitor.applicationActivated(bundleIdentifier: Bundle.main.bundleIdentifier)
        XCTAssertFalse(monitor.showRestartConfirmation)
    }

    @MainActor
    func testGrantWhileSettingsIsFrontmostImmediatelyOffersRestart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var posting = false
        let monitor = ShiftMonitor(defaults: defaults, checkPermission: { false }, requestAccess: { false },
                                   checkEventPostingPermission: { posting }, requestEventPostingAccess: { false })
        defer { monitor.stop() }
        monitor.start(showPermissionExplanation: false)
        XCTAssertFalse(monitor.showRestartConfirmation)
        posting = true
        monitor.refreshPermission()
        XCTAssertTrue(monitor.showRestartConfirmation)
        XCTAssertEqual(monitor.restartPermissionName, "Accessibility")
        monitor.showRestartConfirmation = false
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
    func testBothTonesAre222MillisecondsWithOppositePitchSweepsAndSmoothVolume() throws {
        for tone in BeepPlayer.Tone.allCases {
            let data = BeepPlayer.makeWaveData(tone: tone)
            let player = try AVAudioPlayer(data: data)
            XCTAssertEqual(player.duration, 0.222, accuracy: 0.000001)
            XCTAssertEqual(player.numberOfChannels, 1)
            XCTAssertEqual(data.count, 44 + 10_656 * 2)
            let samples = data.dropFirst(44).withUnsafeBytes { bytes in
                (0..<10_656).map {
                    Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
                }
            }
            XCTAssertEqual(samples.first, 0)
            XCTAssertEqual(samples.last, 0)
            // Measure early and late audible sections, excluding the silent
            // edges where 16-bit quantization can round cycles to zero.
            func measuredPitch(in range: Range<Int>) throws -> (frequency: Double, time: Double) {
                let crossings = range.filter { samples[$0 - 1] <= 0 && samples[$0] > 0 }
                let first = try XCTUnwrap(crossings.first)
                let last = try XCTUnwrap(crossings.last)
                let frequency = 48_000.0 * Double(crossings.count - 1) / Double(last - first)
                let time = Double(first + last) / (2 * 48_000.0)
                return (frequency, time)
            }
            let early = try measuredPitch(in: samples.count / 10..<(samples.count * 4 / 10))
            let late = try measuredPitch(in: samples.count * 6 / 10..<(samples.count * 9 / 10))
            if tone == .pressed {
                XCTAssertGreaterThan(late.frequency, early.frequency)
            } else {
                XCTAssertLessThan(late.frequency, early.frequency)
            }
            for pitch in [early, late] {
                let start = tone == .pressed ? 440.0 : 880.0
                let end = tone == .pressed ? 880.0 : 440.0
                let expectedFrequency = start + (end - start) * pitch.time / 0.222
                XCTAssertEqual(pitch.frequency, expectedFrequency, accuracy: 1)
            }
            XCTAssertLessThanOrEqual(samples.map { abs(Int($0)) }.max()!, 8192)
            XCTAssertGreaterThan(samples.map { abs(Int($0)) }.max()!, 8000)

            func rms(_ samples: ArraySlice<Int16>) -> Double {
                sqrt(samples.reduce(0.0) { $0 + pow(Double($1), 2) } / Double(samples.count))
            }
            let middle = samples.count / 2
            let peakRMS = rms(samples[(middle - 192)..<(middle + 192)])
            // The beginning and end must fade across the whole tone, rather
            // than jumping to full volume after a short edge fade.
            XCTAssertLessThan(rms(samples.prefix(384)), peakRMS * 0.05)
            XCTAssertLessThan(rms(samples.suffix(384)), peakRMS * 0.05)
        }
    }

    @MainActor
    func testVolumeEnvelopeIsSilentAtBothEndsAndPeaksHalfway() {
        XCTAssertEqual(BeepPlayer.volumeEnvelope(progress: 0), 0)
        XCTAssertEqual(BeepPlayer.volumeEnvelope(progress: 0.25), 0.5, accuracy: 0.000001)
        XCTAssertEqual(BeepPlayer.volumeEnvelope(progress: 0.5), 1)
        XCTAssertEqual(BeepPlayer.volumeEnvelope(progress: 0.75), 0.5, accuracy: 0.000001)
        XCTAssertEqual(BeepPlayer.volumeEnvelope(progress: 1), 0)
        XCTAssertLessThan(BeepPlayer.volumeEnvelope(progress: 0.001), 0.0001)
        XCTAssertLessThan(BeepPlayer.volumeEnvelope(progress: 0.999), 0.0001)
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
