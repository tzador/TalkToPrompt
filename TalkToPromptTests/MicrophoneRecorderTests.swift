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
        onFailure: @escaping @Sendable (String) -> Void,
        onIntensities: @escaping @Sendable ([Float]) -> Void,
        onBufferUsage: @escaping @Sendable (RecordingBufferUsage) -> Void
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
    private func tone(frequency: Double, amplitude: Float = 0.2, sampleRate: Double = 48_000,
                      frames: UInt32 = 8192, channels: UInt32 = 1, interleaved: Bool = false) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate, channels: channels, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let value = amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<Int(channels) {
                if interleaved { buffer.floatChannelData![0][frame * Int(channels) + channel] = value }
                else { buffer.floatChannelData![channel][frame] = value }
            }
        }
        return buffer
    }

    func testIntensityProducesOneValuePerTenMillisecondsAtDifferentSampleRates() throws {
        for rate in [22_050.0, 44_100.0, 48_000.0] {
            let analyzer = AudioIntensityAnalyzer(sampleRate: rate)
            let levels = analyzer.consume(try tone(frequency: 1000, sampleRate: rate, frames: UInt32(rate)))
            XCTAssertEqual(levels.count, 100)
            XCTAssertTrue(levels.allSatisfy { $0.isFinite && (0...1).contains($0) })
        }
    }

    func testIntensityKeepsPartialWindowsAcrossTapBuffers() throws {
        let analyzer = AudioIntensityAnalyzer(sampleRate: 48_000)
        let halfWindow = try tone(frequency: 1000, frames: 240)
        XCTAssertTrue(analyzer.consume(halfWindow).isEmpty)
        let first = analyzer.consume(halfWindow)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(analyzer.consume(halfWindow).isEmpty)
        let second = analyzer.consume(halfWindow)
        let combined = AudioIntensityAnalyzer(sampleRate: 48_000).consume(try tone(frequency: 1000, frames: 960))
        XCTAssertEqual(first + second, combined)
    }

    func testIntensityRetainsChronologicalWindowsAndRespondsToVolume() throws {
        let buffer = try tone(frequency: 1000, frames: 1440)
        for frame in 0..<480 { buffer.floatChannelData![0][frame] = 0 }
        for frame in 960..<1440 { buffer.floatChannelData![0][frame] *= 0.05 }
        let levels = AudioIntensityAnalyzer(sampleRate: 48_000).consume(buffer)
        XCTAssertEqual(levels.count, 3)
        XCTAssertEqual(levels[0], 0)
        XCTAssertGreaterThan(levels[1], levels[2] + 0.3)
        XCTAssertGreaterThan(levels[2], 0)
    }

    func testIntensitySumsChannelVolumesWithoutPhaseCancellation() throws {
        let mono = AudioIntensityAnalyzer(sampleRate: 48_000).consume(try tone(frequency: 1000, frames: 480))
        for interleaved in [false, true] {
            let buffer = try tone(frequency: 1000, frames: 480, channels: 2, interleaved: interleaved)
            for frame in 0..<480 {
                if interleaved { buffer.floatChannelData![0][frame * 2 + 1] *= -1 }
                else { buffer.floatChannelData![1][frame] *= -1 }
            }
            let levels = AudioIntensityAnalyzer(sampleRate: 48_000).consume(buffer)
            XCTAssertEqual(levels, mono)
        }
    }

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

    func testStreamingConversionProduces16kHz16BitMonoWAVFromCommonInputFormats() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            for channels: UInt32 in [1, 2] {
                let input = try tone(frequency: 1000, sampleRate: rate, frames: UInt32(rate / 100), channels: channels)
                let capture = try PCMRecordingCapture(inputFormat: input.format)
                var firstCallbacks = 0
                var previousBytes = RecordingBufferUsage.headerBytes
                for _ in 0..<100 {
                    if let update = try capture.append(input) {
                        if update.first { firstCallbacks += 1 }
                        XCTAssertGreaterThanOrEqual(update.usage.byteCount, previousBytes)
                        previousBytes = update.usage.byteCount
                    }
                }
                let recording = capture.finish()
                XCTAssertEqual(firstCallbacks, 1)
                XCTAssertEqual(recording.sampleRate, 16_000)
                XCTAssertEqual(recording.channelCount, 1)
                XCTAssertEqual(recording.commonFormat, .pcmFormatInt16)
                XCTAssertTrue(recording.isInterleaved)
                XCTAssertEqual(Double(recording.frameCount), 16_000, accuracy: 2)
                let wave = try recording.makeWaveData()
                XCTAssertEqual(wave.count, 44 + Int(recording.frameCount) * 2)
                // WAV: PCM code 1, mono, 16000 Hz, 16 bits per sample.
                XCTAssertEqual(wave[20], 1)
                XCTAssertEqual(wave[22], 1)
                XCTAssertEqual(wave[24..<28], Data([0x80, 0x3e, 0, 0]))
                XCTAssertEqual(wave[34], 16)
                XCTAssertTrue(recording.chunks.contains { chunk in
                    chunk.planes[0].contains { $0 != 0 }
                })
                XCTAssertNil(try capture.append(input))
            }
        }
    }

    func testStreamingConversionIncludesBothStereoChannelsInMonoOutput() throws {
        let input = try tone(frequency: 1000, frames: 4800, channels: 2)
        for frame in 0..<4800 { input.floatChannelData![0][frame] = 0 }
        let capture = try PCMRecordingCapture(inputFormat: input.format)
        _ = try capture.append(input)
        let recording = capture.finish()
        XCTAssertTrue(recording.chunks.contains { $0.planes[0].contains { $0 != 0 } })
    }

    func testCaptureTrimsLastChunkAtExactWAVLimitAndRejectsLaterAudio() throws {
        let input = try tone(frequency: 1000, frames: 8192, channels: 2)
        // A small injected budget exercises the real conversion/cutoff without a long recording.
        let limit = 44 + 3200
        let capture = try PCMRecordingCapture(inputFormat: input.format, maximumWaveBytes: limit)
        let update = try XCTUnwrap(capture.append(input))
        XCTAssertTrue(update.first)
        XCTAssertEqual(update.usage.byteCount, limit)
        XCTAssertNil(try capture.append(input))
        let recording = capture.finish()
        XCTAssertEqual(recording.frameCount, 1600)
        XCTAssertEqual(try recording.makeWaveData().count, limit)
    }

    func testBufferUsageIncludesHeaderAndUses24MBAsCapacity() {
        XCTAssertEqual(RecordingBufferUsage.empty.byteCount, 44)
        XCTAssertEqual(RecordingBufferUsage.empty.remainingSeconds, 360)
        XCTAssertFalse(RecordingBufferUsage(byteCount: 19_999_999).isWarning)
        let warning = RecordingBufferUsage(byteCount: 20_000_000)
        XCTAssertTrue(warning.isWarning)
        XCTAssertEqual(warning.fraction, 5.0 / 6, accuracy: 0.000001)
        XCTAssertEqual(warning.remainingSeconds, 125)
        XCTAssertFalse(warning.isFull)
        let full = RecordingBufferUsage(byteCount: 24_000_000)
        XCTAssertTrue(full.isFull)
        XCTAssertEqual(full.fraction, 1)
        XCTAssertEqual(full.remainingSeconds, 0)
    }

    func testTimeThresholdsWarnAtFiveMinutesAndStopAtSix() {
        let bytes = RecordingBufferUsage.headerBytes
        XCTAssertFalse(RecordingBufferUsage(byteCount: bytes, elapsedSeconds: 299.999).isWarning)
        let warning = RecordingBufferUsage(byteCount: bytes, elapsedSeconds: 300)
        XCTAssertTrue(warning.isWarning)
        XCTAssertFalse(warning.isFull)
        XCTAssertEqual(warning.remainingSeconds, 60)
        XCTAssertFalse(RecordingBufferUsage(byteCount: bytes, elapsedSeconds: 359.999).isFull)
        let full = RecordingBufferUsage(byteCount: bytes, elapsedSeconds: 360)
        XCTAssertTrue(full.isFull)
        XCTAssertEqual(full.remainingSeconds, 0)
    }

    func testCaptureCannotRetainMoreThanSixMinutesEvenWithoutUICallback() throws {
        let input = try tone(frequency: 1000, sampleRate: 16_000, frames: 16_000 * 60)
        let capture = try PCMRecordingCapture(inputFormat: input.format)
        var lastUsage = RecordingBufferUsage.empty
        for _ in 0..<7 {
            if let update = try capture.append(input) { lastUsage = update.usage }
        }
        XCTAssertTrue(lastUsage.isFull)
        XCTAssertEqual(lastUsage.elapsedSeconds, 360)
        XCTAssertEqual(lastUsage.byteCount, 11_520_044)
        XCTAssertNil(try capture.append(input))
        let recording = capture.finish()
        XCTAssertEqual(recording.duration, 360)
        XCTAssertEqual(try recording.makeWaveData().count, 11_520_044)
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
    func testOnboardingPermissionRequestDoesNotStartRecording() async {
        let capture = FakeMicrophoneCapture()
        var authorization: AVAuthorizationStatus = .notDetermined
        var requests = 0
        let session = MicrophoneRecordingSession(capture: capture, checkAuthorization: { authorization }, requestAccess: {
            requests += 1
            authorization = .authorized
            return true
        })
        await session.requestPermission()
        await session.requestPermission()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(session.authorization, .authorized)
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
