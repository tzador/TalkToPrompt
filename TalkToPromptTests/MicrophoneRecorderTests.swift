import AVFoundation
import XCTest
@testable import TalkToPrompt

private actor FakeMicrophoneCapture: MicrophoneCapturing {
    private(set) var starts: [UUID] = []
    private(set) var stops: [UUID] = []
    var failStart = false
    private var ready: [UUID: @Sendable () -> Void] = [:]
    private var failures: [UUID: @Sendable (String) -> Void] = [:]

    func start(
        id: UUID, onFirstAudio: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        if failStart { throw NSError(domain: "MicrophoneTest", code: 1) }
        starts.append(id)
        ready[id] = onFirstAudio
        failures[id] = onFailure
    }

    func stop(id: UUID) -> MicrophoneRecording? {
        stops.append(id)
        return MicrophoneRecording(
            sampleRate: 48_000, channelCount: 1, commonFormat: .pcmFormatFloat32,
            isInterleaved: false, chunks: [.init(frameCount: 480, planes: [Data(count: 480 * 4)])]
        )
    }

    func sendFirstAudio(id: UUID) { ready[id]?() }
    func sendFailure(id: UUID) { failures[id]?("Input device disconnected") }
    func setFailStart() { failStart = true }
}

final class MicrophoneRecorderTests: XCTestCase {
    func testCapturedPCMIsOwnedAndPreservesAllChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        for channel in 0..<2 {
            for frame in 0..<64 { buffer.floatChannelData![channel][frame] = channel == 0 ? 0.25 : 0.5 }
        }
        let audio = InMemoryAudioCapture(format: format)
        XCTAssertTrue(audio.append(buffer))
        // Audio-engine buffers are reused; mutating one must not change our copy.
        buffer.floatChannelData![0][0] = 0
        let recording = audio.finish()
        XCTAssertEqual(recording.frameCount, 64)
        XCTAssertEqual(recording.channelCount, 2)
        XCTAssertEqual(recording.sampleRate, 48_000)
        XCTAssertFalse(recording.isInterleaved)
        XCTAssertEqual(recording.chunks[0].planes.count, 2)
        XCTAssertEqual(recording.chunks[0].planes[0].count, 64 * 4)
        XCTAssertEqual(recording.chunks[0].planes[0].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, 0.25)
        XCTAssertEqual(recording.chunks[0].planes[1].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, 0.5)
        XCTAssertFalse(audio.append(buffer))
        XCTAssertEqual(recording.frameCount, 64)
    }

    func testInterleavedPCMAndDurationArePreserved() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        buffer.frameLength = 240
        let audio = InMemoryAudioCapture(format: format)
        XCTAssertTrue(audio.append(buffer))
        XCTAssertFalse(audio.append(buffer))
        let recording = audio.finish()
        XCTAssertTrue(recording.isInterleaved)
        XCTAssertEqual(recording.chunks.count, 2)
        XCTAssertEqual(recording.chunks[0].planes.count, 1)
        XCTAssertEqual(recording.chunks[0].planes[0].count, 240 * 2 * 4)
        XCTAssertEqual(recording.frameCount, 480)
        XCTAssertEqual(recording.duration, 0.01, accuracy: 0.000001)
    }

    func testEmptyBuffersDoNotIndicateRecordingHasStarted() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 0
        let audio = InMemoryAudioCapture(format: format)
        XCTAssertFalse(audio.append(buffer))
        XCTAssertTrue(audio.finish().chunks.isEmpty)
    }

    func testReleaseBeforeHardwareStartCancelsWithoutOpeningMicrophone() async {
        let recorder = MicrophoneRecorder()
        let id = UUID()
        _ = await recorder.stop(id: id)
        do {
            try await recorder.start(id: id, onFirstAudio: {}, onFailure: { _ in })
            XCTFail("A released session must never open hardware")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    private func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<100 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for recording state")
    }

    @MainActor
    func testListeningBeginsOnlyAfterFirstAudioAndFinishReleasesCapture() async {
        let capture = FakeMicrophoneCapture()
        let session = MicrophoneRecordingSession(capture: capture, checkAuthorization: { .authorized }, requestAccess: { XCTFail("Already authorized"); return true })
        var listeningCallbacks = 0
        session.onFirstAudio = { listeningCallbacks += 1 }
        session.begin()
        await waitUntil { await capture.starts.count == 1 }
        XCTAssertFalse(session.isRecording)
        let id = await capture.starts[0]
        await capture.sendFirstAudio(id: id)
        await waitUntil { session.isRecording }
        XCTAssertEqual(listeningCallbacks, 1)
        session.finish()
        XCTAssertFalse(session.isRecording)
        await waitUntil { await capture.stops.count == 1 }
        await waitUntil { session.latestRecording != nil }
        XCTAssertEqual(session.latestRecording?.duration ?? 0, 0.01, accuracy: 0.000001)
    }

    @MainActor
    func testReleaseWhilePermissionIsPendingNeverStartsCaptureAfterGrant() async {
        let capture = FakeMicrophoneCapture()
        var authorization: AVAuthorizationStatus = .notDetermined
        var permissionReply: CheckedContinuation<Bool, Never>?
        let session = MicrophoneRecordingSession(
            capture: capture, checkAuthorization: { authorization },
            requestAccess: { await withCheckedContinuation { permissionReply = $0 } }
        )
        session.begin()
        await waitUntil { permissionReply != nil }
        session.finish()
        authorization = .authorized
        permissionReply?.resume(returning: true)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(session.isRecording)
        let starts = await capture.starts
        XCTAssertTrue(starts.isEmpty)
    }

    @MainActor
    func testDeniedPermissionDoesNotOpenMicrophone() async {
        let capture = FakeMicrophoneCapture()
        let session = MicrophoneRecordingSession(capture: capture, checkAuthorization: { .denied }, requestAccess: { XCTFail("Do not repeatedly request denied permission"); return false })
        session.begin()
        await waitUntil { session.errorMessage != nil }
        XCTAssertFalse(session.isRecording)
        let starts = await capture.starts
        XCTAssertTrue(starts.isEmpty)
    }

    @MainActor
    func testPermissionGrantStartsCaptureIfChordIsStillHeld() async {
        let capture = FakeMicrophoneCapture()
        var authorization: AVAuthorizationStatus = .notDetermined
        let session = MicrophoneRecordingSession(
            capture: capture, checkAuthorization: { authorization },
            requestAccess: { authorization = .authorized; return true }
        )
        session.begin()
        await waitUntil { await capture.starts.count == 1 }
        XCTAssertEqual(session.authorization, .authorized)
        session.finish()
    }

    @MainActor
    func testStaleAudioCallbackDoesNotReenableListeningAfterRelease() async {
        let capture = FakeMicrophoneCapture()
        let session = MicrophoneRecordingSession(capture: capture, checkAuthorization: { .authorized })
        session.begin()
        await waitUntil { await capture.starts.count == 1 }
        let oldID = await capture.starts[0]
        session.finish()
        await capture.sendFirstAudio(id: oldID)
        await Task.yield()
        XCTAssertFalse(session.isRecording)
    }

    @MainActor
    func testHardwareFailureIsReported() async {
        let capture = FakeMicrophoneCapture()
        await capture.setFailStart()
        let session = MicrophoneRecordingSession(capture: capture, checkAuthorization: { .authorized })
        session.begin()
        await waitUntil { session.errorMessage != nil }
        XCTAssertFalse(session.isRecording)
    }

    @MainActor
    func testRapidSecondHoldIgnoresOldAudioCallbacksAndOldRecording() async {
        let capture = FakeMicrophoneCapture()
        let session = MicrophoneRecordingSession(capture: capture, checkAuthorization: { .authorized })
        session.begin()
        await waitUntil { await capture.starts.count == 1 }
        let firstID = await capture.starts[0]
        session.finish()
        session.begin()
        await waitUntil { await capture.starts.count == 2 }
        let secondID = await capture.starts[1]
        await capture.sendFirstAudio(id: firstID)
        await Task.yield()
        XCTAssertFalse(session.isRecording)
        XCTAssertNil(session.latestRecording)
        await capture.sendFirstAudio(id: secondID)
        await waitUntil { session.isRecording }
        session.finish()
        await waitUntil { session.latestRecording != nil }
        XCTAssertFalse(session.isRecording)
    }

    @MainActor
    func testPermissionRevocationStopsAnActiveRecording() async {
        let capture = FakeMicrophoneCapture()
        var authorization: AVAuthorizationStatus = .authorized
        let session = MicrophoneRecordingSession(capture: capture, checkAuthorization: { authorization })
        session.begin()
        await waitUntil { await capture.starts.count == 1 }
        let id = await capture.starts[0]
        await capture.sendFirstAudio(id: id)
        await waitUntil { session.isRecording }
        authorization = .denied
        session.refreshPermission()
        XCTAssertFalse(session.isRecording)
        await waitUntil { await capture.stops.count == 1 }
    }

    @MainActor
    func testInputDeviceChangeEndsRecordingAndReportsFailure() async {
        let capture = FakeMicrophoneCapture()
        let session = MicrophoneRecordingSession(capture: capture, checkAuthorization: { .authorized })
        session.begin()
        await waitUntil { await capture.starts.count == 1 }
        let id = await capture.starts[0]
        await capture.sendFailure(id: id)
        await waitUntil { session.errorMessage != nil }
        await waitUntil { await capture.stops.count == 1 }
        XCTAssertFalse(session.isRecording)
    }
}
