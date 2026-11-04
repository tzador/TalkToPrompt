import AVFoundation
import XCTest
@testable import TalkToPrompt

private actor SessionCapture: MicrophoneCapturing {
    private(set) var starts: [UUID] = []
    private(set) var stops: [UUID] = []
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private var waitForStop = false
    private var stopReply: CheckedContinuation<MicrophoneRecording?, Never>?

    func start(id: UUID, onFirstAudio: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        starts.append(id)
        callbacks[id] = onFirstAudio
    }
    func stop(id: UUID) async -> MicrophoneRecording? {
        stops.append(id)
        if waitForStop { return await withCheckedContinuation { stopReply = $0 } }
        return Self.recording
    }
    func firstAudio() { if let id = starts.last { callbacks[id]?() } }
    func delayStop() { waitForStop = true }
    func completeStop() { stopReply?.resume(returning: Self.recording); stopReply = nil }
    private static var recording: MicrophoneRecording {
        .init(sampleRate: 48_000, channelCount: 1, commonFormat: .pcmFormatFloat32,
              isInterleaved: false, chunks: [.init(frameCount: 480, planes: [Data(count: 1920)])])
    }
}

@MainActor
private final class SessionOverlay: VoiceSessionOverlay {
    var visible = false
    var message: String?
    var hides = 0
    var completions: [() -> Void] = []
    func show() { visible = true }
    func setMessage(_ message: String?) { self.message = message }
    func hide(completion: (() -> Void)?) {
        hides += 1
        if !visible { completion?() }
        else if let completion { completions.append(completion) }
    }
    func hideImmediately() { visible = false; message = nil }
    func completeFade() {
        visible = false
        if !completions.isEmpty { completions.removeFirst()() }
    }
}

@MainActor
private final class SessionPlayer: RecordingPlaying {
    var currentTime: TimeInterval = 0
    var plays = 0
    var stops = 0
    var fail = false
    var completion: ((String?) -> Void)?
    func play(_ recording: MicrophoneRecording, onFinished: @escaping (String?) -> Void) async throws {
        plays += 1
        if fail { throw NSError(domain: "PlaybackTest", code: 1) }
        completion = onFinished
    }
    func stop() { stops += 1; currentTime = 0 }
}

@MainActor
private final class VoiceFixture {
    let capture = SessionCapture()
    let overlay = SessionOverlay()
    let player = SessionPlayer()
    var clock: TimeInterval = 100
    var begins = 0
    var exits = 0
    var errors: [String] = []
    lazy var microphone = MicrophoneRecordingSession(capture: capture, checkAuthorization: { .authorized })
    lazy var voice = VoiceSessionController(
        microphone: microphone, overlay: overlay, player: player,
        now: { [unowned self] in clock },
        onBegin: { [unowned self] in begins += 1 },
        onExit: { [unowned self] in exits += 1 },
        onError: { [unowned self] in errors.append($0) }
    )
}

final class VoiceSessionControllerTests: XCTestCase {
    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for voice session state")
    }

    @MainActor
    private func listen(_ fixture: VoiceFixture) async {
        XCTAssertTrue(fixture.voice.begin())
        await waitUntil { await fixture.capture.starts.count == 1 }
        await fixture.capture.firstAudio()
        await waitUntil { fixture.voice.phase == .listening }
    }

    @MainActor
    func testListeningCounterStartsAtFirstAudioAndUsesElapsedSeconds() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        XCTAssertEqual(f.overlay.message, "Listening... 0 seconds")
        f.clock = 113.9
        f.voice.updateStatus()
        XCTAssertEqual(f.overlay.message, "Listening... 13 seconds")
        XCTAssertEqual(f.begins, 1)
    }

    @MainActor
    func testReleaseStopsMicrophoneAndKeepsOverlayForPlayback() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        f.voice.finish()
        await waitUntil { f.voice.phase == .speaking }
        let stops = await f.capture.stops
        XCTAssertEqual(stops.count, 1)
        XCTAssertTrue(f.overlay.visible)
        XCTAssertEqual(f.overlay.hides, 0)
        XCTAssertEqual(f.player.plays, 1)
        f.clock = 500
        f.player.currentTime = 4.8
        f.voice.updateStatus()
        XCTAssertEqual(f.overlay.message, "Speaking... 4 seconds")
        f.player.completion?(nil)
        XCTAssertEqual(f.voice.phase, .closing)
        XCTAssertEqual(f.exits, 1)
        f.overlay.completeFade()
        XCTAssertEqual(f.voice.phase, .idle)
    }

    @MainActor
    func testDoubleShiftIsIgnoredDuringEveryOpenPhaseIncludingFadeOut() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        XCTAssertTrue(f.voice.begin())
        XCTAssertFalse(f.voice.begin())
        await waitUntil { await f.capture.starts.count == 1 }
        await f.capture.firstAudio()
        await waitUntil { f.voice.phase == .listening }
        XCTAssertFalse(f.voice.begin())
        await f.capture.delayStop()
        f.voice.finish()
        XCTAssertEqual(f.voice.phase, .finishing)
        XCTAssertFalse(f.voice.begin())
        await waitUntil { await f.capture.stops.count == 1 }
        await f.capture.completeStop()
        await waitUntil { f.voice.phase == .speaking }
        XCTAssertFalse(f.voice.begin())
        f.voice.finish() // Release of an ignored second chord must not end playback.
        XCTAssertEqual(f.voice.phase, .speaking)
        f.player.completion?(nil)
        XCTAssertFalse(f.voice.begin())
        f.overlay.completeFade()
        XCTAssertTrue(f.voice.begin())
        XCTAssertEqual(f.begins, 2)
    }

    @MainActor
    func testCancellationDuringListeningStopsCaptureAndPlaysExitOnlyOnce() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        f.voice.cancel()
        f.voice.cancel()
        await waitUntil { await f.capture.stops.count == 1 }
        XCTAssertEqual(f.voice.phase, .closing)
        XCTAssertEqual(f.player.plays, 0)
        XCTAssertEqual(f.exits, 1)
        f.overlay.completeFade()
        XCTAssertEqual(f.voice.phase, .idle)
    }

    @MainActor
    func testCancellationWhileCaptureStopsCannotStartLatePlayback() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        await f.capture.delayStop()
        f.voice.finish()
        await waitUntil { await f.capture.stops.count == 1 }
        f.voice.cancel()
        await f.capture.completeStop()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(f.player.plays, 0)
        XCTAssertEqual(f.voice.phase, .closing)
        XCTAssertEqual(f.exits, 1)
    }

    @MainActor
    func testCancellationStopsPlaybackAndIgnoresItsLateCompletion() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        f.voice.finish()
        await waitUntil { f.voice.phase == .speaking }
        let completion = f.player.completion
        f.voice.cancel()
        XCTAssertEqual(f.player.stops, 1)
        XCTAssertEqual(f.voice.phase, .closing)
        completion?(nil)
        XCTAssertEqual(f.exits, 1)
        XCTAssertEqual(f.overlay.hides, 1)
    }

    @MainActor
    func testPlaybackFailureReportsErrorAndClosesOverlay() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        f.player.fail = true
        await listen(f)
        f.voice.finish()
        await waitUntil { f.voice.phase == .closing }
        XCTAssertEqual(f.errors.count, 1)
        XCTAssertEqual(f.exits, 1)
        XCTAssertFalse(f.microphone.isRecording)
    }

    @MainActor
    func testCancellationWhileConsentIsPendingDoesNotRecordAfterGrant() async {
        let capture = SessionCapture()
        let overlay = SessionOverlay()
        let player = SessionPlayer()
        var authorization: AVAuthorizationStatus = .notDetermined
        var reply: CheckedContinuation<Bool, Never>?
        let microphone = MicrophoneRecordingSession(
            capture: capture, checkAuthorization: { authorization },
            requestAccess: { await withCheckedContinuation { reply = $0 } }
        )
        let voice = VoiceSessionController(microphone: microphone, overlay: overlay, player: player)
        defer { voice.stopImmediately() }
        voice.begin()
        await waitUntil { reply != nil }
        voice.cancel()
        authorization = .authorized
        reply?.resume(returning: true)
        try? await Task.sleep(for: .milliseconds(20))
        let starts = await capture.starts
        XCTAssertTrue(starts.isEmpty)
        XCTAssertFalse(overlay.visible)
        XCTAssertEqual(player.plays, 0)
        XCTAssertEqual(voice.phase, .idle)
    }

    @MainActor
    func testShutdownImmediatelyStopsSessionWithoutExitCue() async {
        let f = VoiceFixture()
        await listen(f)
        f.voice.stopImmediately()
        XCTAssertEqual(f.voice.phase, .idle)
        XCTAssertFalse(f.overlay.visible)
        XCTAssertEqual(f.exits, 0)
        await waitUntil { await f.capture.stops.count == 1 }
    }

    @MainActor
    func testStaleFadeCompletionCannotCloseANewerSession() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        f.voice.cancel()
        let oldCompletion = f.overlay.completions.removeFirst()
        f.voice.stopImmediately()
        XCTAssertTrue(f.voice.begin())
        f.voice.cancel()
        oldCompletion()
        XCTAssertEqual(f.voice.phase, .closing)
        f.overlay.completeFade()
        XCTAssertEqual(f.voice.phase, .idle)
    }
}
