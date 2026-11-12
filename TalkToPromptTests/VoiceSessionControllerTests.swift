import AVFoundation
import XCTest
@testable import TalkToPrompt

private actor SessionCapture: MicrophoneCapturing {
    private(set) var starts: [UUID] = []
    private(set) var stops: [UUID] = []
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private var intensityBatches: [UUID: @Sendable ([Float]) -> Void] = [:]
    private var waitForStop = false
    private var stopReply: CheckedContinuation<MicrophoneRecording?, Never>?

    func start(id: UUID, onFirstAudio: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable (String) -> Void,
               onIntensities: @escaping @Sendable ([Float]) -> Void) {
        starts.append(id)
        callbacks[id] = onFirstAudio
        intensityBatches[id] = onIntensities
    }
    func stop(id: UUID) async -> MicrophoneRecording? {
        stops.append(id)
        if waitForStop { return await withCheckedContinuation { stopReply = $0 } }
        return Self.recording
    }
    func firstAudio() { if let id = starts.last { callbacks[id]?() } }
    func intensities(_ values: [Float]) { if let id = starts.last { intensityBatches[id]?(values) } }
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
    var intensityBatches: [[Float]] = []
    var hides = 0
    var completions: [() -> Void] = []
    func show() { visible = true }
    func setMessage(_ message: String?) { self.message = message }
    func appendIntensities(_ values: [Float]) { intensityBatches.append(values) }
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

private actor SessionTranscriber: AudioTranscribing {
    var requests = 0
    var languages: [String?] = []
    var fail = false
    var wasCancelled = false
    var pending: CheckedContinuation<String, Error>?
    func transcribe(_ recording: MicrophoneRecording, apiKey: String, language: String?) async throws -> String {
        requests += 1
        languages.append(language)
        if fail { throw OpenAITranscriber.TranscriptionError.rejected(401, false) }
        let text = try await withCheckedThrowingContinuation { pending = $0 }
        wasCancelled = Task.isCancelled
        return text
    }
    func complete(text: String = "hello, world") { pending?.resume(returning: text); pending = nil }
    func setFailure() { fail = true }
}

@MainActor
private final class VoiceFixture {
    let capture = SessionCapture()
    let overlay = SessionOverlay()
    let transcriber = SessionTranscriber()
    var key: String? = "sk-test-only"
    var preferredLanguage: String?
    var pasted: [String] = []
    var restores = 0
    var pasteFails = false
    var clock: TimeInterval = 100
    var begins = 0
    var exits = 0
    var errors: [String] = []
    lazy var microphone = MicrophoneRecordingSession(capture: capture, checkAuthorization: { .authorized })
    lazy var voice = VoiceSessionController(
        microphone: microphone, overlay: overlay, transcriber: transcriber,
        loadAPIKey: { [unowned self] in key },
        insertText: { [unowned self] in
            if pasteFails { throw ClipboardTextInserter.InsertionError.permissionRequired }
            pasted.append($0)
        },
        restoreClipboard: { [unowned self] in restores += 1 },
        now: { [unowned self] in clock },
        onBegin: { [unowned self] in begins += 1 },
        onExit: { [unowned self] in exits += 1 },
        onError: { [unowned self] in errors.append($0) },
        preferredLanguage: { [unowned self] in preferredLanguage }
    )
}

final class VoiceSessionControllerTests: XCTestCase {
    @MainActor
    func testInputLanguageIsCapturedAtBeginningOfEachRecording() async {
        for initial in [nil, "uk"] as [String?] {
            let f = VoiceFixture()
            defer { f.voice.stopImmediately() }
            f.preferredLanguage = initial
            await listen(f)
            f.preferredLanguage = "de"
            f.voice.finish()
            await waitUntil { await f.transcriber.requests == 1 }
            let languages = await f.transcriber.languages
            XCTAssertEqual(languages, [initial])
            await f.transcriber.complete(text: "Добрий день")
            await waitUntil { f.voice.phase == .closing }
            XCTAssertEqual(f.pasted, ["Добрий день"])
        }
    }

    @MainActor
    func testIntensitiesReachesOverlayOnlyWhileListeningAndIgnoresLateCallbacks() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        let values: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        await f.capture.intensities(values)
        await waitUntil { f.overlay.intensityBatches.count == 1 }
        XCTAssertEqual(f.overlay.intensityBatches.last, values)
        f.voice.finish()
        await f.capture.intensities(Array(repeating: 1, count: 8))
        await waitUntil { await f.transcriber.requests == 1 }
        XCTAssertEqual(f.overlay.intensityBatches.count, 1)
        await f.transcriber.complete()
        await waitUntil { f.voice.phase == .closing }
        f.overlay.completeFade()
        XCTAssertTrue(f.voice.begin())
        await waitUntil { await f.capture.starts.count == 2 }
        // Before the second capture's first audio, intensity updates are discarded.
        await f.capture.intensities(values)
        await f.capture.firstAudio()
        await waitUntil { f.voice.phase == .listening }
        XCTAssertEqual(f.overlay.intensityBatches.count, 1)
    }

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
    func testTranscriptsIncludingFormerCommandsArePastedVerbatim() async {
        for text in ["Добрий день", "Translate to Spanish.", "Don't translate", "No translation", "Translation off", "Spanish", "Auto"] {
            let f = VoiceFixture()
            await listen(f)
            f.voice.finish()
            await waitUntil { await f.transcriber.requests == 1 }
            await f.transcriber.complete(text: text)
            await waitUntil { f.voice.phase == .closing }
            XCTAssertEqual(f.pasted, [text])
            XCTAssertTrue(f.errors.isEmpty)
            f.overlay.completeFade()
            XCTAssertEqual(f.voice.phase, .idle)
            f.voice.stopImmediately()
        }
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
    func testReleaseTranscribesThenPastesAndFades() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        f.voice.finish()
        XCTAssertEqual(f.overlay.message, "Transcribing...")
        await waitUntil { await f.transcriber.requests == 1 }
        let stops = await f.capture.stops.count
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(f.overlay.visible)
        XCTAssertFalse(f.voice.begin())
        f.voice.finish() // Release of an ignored chord must not cancel the request.
        await f.transcriber.complete()
        await waitUntil { f.voice.phase == .closing }
        XCTAssertEqual(f.pasted, ["hello, world"])
        XCTAssertFalse(f.voice.begin())
        f.overlay.completeFade()
        XCTAssertEqual(f.voice.phase, .idle)
        XCTAssertEqual(f.exits, 1)
    }

    @MainActor
    func testNoSpeechClosesQuietlyWithoutPasting() async {
        for text in ["", "  \n "] {
            let f = VoiceFixture()
            await listen(f)
            f.voice.finish()
            await waitUntil { await f.transcriber.requests == 1 }
            await f.transcriber.complete(text: text)
            await waitUntil { f.voice.phase == .closing }
            XCTAssertTrue(f.pasted.isEmpty)
            f.overlay.completeFade()
            XCTAssertEqual(f.voice.phase, .idle)
            XCTAssertTrue(f.errors.isEmpty)
            f.voice.stopImmediately()
        }
    }

    @MainActor
    func testMissingKeyShowsMessageWithoutRecordingAndClosesOnRelease() async {
        let f = VoiceFixture()
        f.key = nil
        XCTAssertTrue(f.voice.begin())
        XCTAssertEqual(f.overlay.message, "No OpenAI API key provided")
        XCTAssertTrue(f.overlay.visible)
        XCTAssertFalse(f.voice.begin())
        let starts = await f.capture.starts.count
        XCTAssertEqual(starts, 0)
        f.voice.finish()
        f.overlay.completeFade()
        XCTAssertEqual(f.voice.phase, .idle)
        XCTAssertTrue(f.pasted.isEmpty)
    }

    @MainActor
    func testErrorIsPresentedOnlyAfterOverlayCloses() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await f.transcriber.setFailure()
        await listen(f)
        f.voice.finish()
        await waitUntil { f.voice.phase == .closing }
        XCTAssertTrue(f.errors.isEmpty)
        f.overlay.completeFade()
        XCTAssertEqual(f.errors.count, 1)
        XCTAssertTrue(f.errors[0].contains("API key"))
        XCTAssertTrue(f.pasted.isEmpty)
    }

    @MainActor
    func testPasteFailureClosesBeforeShowingPermissionGuidance() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        f.pasteFails = true
        await listen(f)
        f.voice.finish()
        await waitUntil { await f.transcriber.requests == 1 }
        await f.transcriber.complete()
        await waitUntil { f.voice.phase == .closing }
        XCTAssertTrue(f.errors.isEmpty)
        f.overlay.completeFade()
        XCTAssertTrue(f.errors.first?.contains("Accessibility") == true)
        XCTAssertTrue(f.pasted.isEmpty)
    }

    @MainActor
    func testShutdownDuringRequestPreventsLatePasteAndRestoresClipboard() async {
        let f = VoiceFixture()
        await listen(f)
        f.voice.finish()
        await waitUntil { await f.transcriber.requests == 1 }
        f.voice.stopImmediately()
        await f.transcriber.complete()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(f.pasted.isEmpty)
        XCTAssertEqual(f.restores, 1)
        XCTAssertEqual(f.voice.phase, .idle)
        XCTAssertFalse(f.overlay.visible)
        XCTAssertTrue(f.errors.isEmpty)
    }

    @MainActor
    func testCancelDuringPreparationStopsBeforeCaptureAndFadesOnce() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        XCTAssertTrue(f.voice.begin())
        XCTAssertEqual(f.voice.phase, .preparing)
        f.voice.cancel()
        f.voice.cancel() // Repeated Escape must not restart the exit animation.
        f.voice.finish() // Releasing Shift after Escape must not transcribe.
        XCTAssertEqual(f.voice.phase, .closing)
        XCTAssertTrue(f.overlay.visible)
        XCTAssertEqual(f.overlay.hides, 1)
        XCTAssertEqual(f.exits, 1)
        XCTAssertEqual(f.restores, 1)
        f.overlay.completeFade()
        try? await Task.sleep(for: .milliseconds(20))
        let starts = await f.capture.starts.count
        let requests = await f.transcriber.requests
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(f.voice.phase, .idle)
    }

    @MainActor
    func testCancelWhileListeningStopsCaptureWithoutTranscribing() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        f.voice.cancel()
        f.voice.finish()
        XCTAssertFalse(f.microphone.isRecording)
        XCTAssertEqual(f.voice.phase, .closing)
        XCTAssertTrue(f.overlay.visible)
        await waitUntil { await f.capture.stops.count == 1 }
        await f.capture.firstAudio()
        await f.capture.intensities([1])
        f.overlay.completeFade()
        try? await Task.sleep(for: .milliseconds(20))
        let requests = await f.transcriber.requests
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(f.overlay.intensityBatches.isEmpty)
        XCTAssertTrue(f.pasted.isEmpty)
        XCTAssertTrue(f.errors.isEmpty)
        XCTAssertEqual(f.voice.phase, .idle)
    }

    @MainActor
    func testCancelDuringTranscriptionIgnoresLateResultAfterNextSessionBegins() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        f.voice.finish()
        await waitUntil { await f.transcriber.requests == 1 }
        f.voice.cancel()
        XCTAssertEqual(f.voice.phase, .closing)
        XCTAssertEqual(f.overlay.hides, 1)
        XCTAssertTrue(f.overlay.visible)
        XCTAssertFalse(f.voice.begin())
        f.overlay.completeFade()
        XCTAssertTrue(f.voice.begin())
        await f.transcriber.complete(text: "cancelled transcript")
        await waitUntil { await f.transcriber.wasCancelled }
        XCTAssertEqual(f.voice.phase, .preparing)
        XCTAssertTrue(f.overlay.visible)
        XCTAssertTrue(f.pasted.isEmpty)
        XCTAssertTrue(f.errors.isEmpty)
        XCTAssertEqual(f.restores, 1)
    }

    @MainActor
    func testCancelWithMissingKeyAndWhileIdle() {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        f.voice.cancel()
        XCTAssertEqual(f.overlay.hides, 0)
        f.key = nil
        XCTAssertTrue(f.voice.begin())
        f.voice.cancel()
        XCTAssertEqual(f.voice.phase, .closing)
        XCTAssertEqual(f.overlay.hides, 1)
        f.overlay.completeFade()
        XCTAssertEqual(f.voice.phase, .idle)
        XCTAssertTrue(f.errors.isEmpty)
    }

    @MainActor
    func testCancellationWhileCaptureStopsPreventsUpload() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        await f.capture.delayStop()
        f.voice.finish()
        await waitUntil { await f.capture.stops.count == 1 }
        f.voice.cancel()
        await f.capture.completeStop()
        try? await Task.sleep(for: .milliseconds(20))
        let requests = await f.transcriber.requests
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(f.pasted.isEmpty)
    }
}

final class OpenAITranscriberTests: XCTestCase {
    func testLanguageHintUsesArrayFieldAndAutoOmitsIt() async throws {
        for code in [nil, "uk", "yue", "zh-tw", "invalid\r\nfield"] as [String?] {
            let client = OpenAITranscriber { request in
                let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
                if let hint = TranscriptionLanguage.validated(code) {
                    XCTAssertTrue(body.contains("name=\"languages[]\"\r\n\r\n\(hint)\r\n"))
                } else {
                    XCTAssertFalse(body.contains("name=\"languages[]\""))
                }
                XCTAssertFalse(body.contains("name=\"language\""))
                return (Data("{\"text\":\"Добрий день\"}".utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let text = try await client.transcribe(recording, apiKey: "sk-test-only", language: code)
            XCTAssertEqual(text, "Добрий день")
        }
    }

    private var recording: MicrophoneRecording {
        .init(sampleRate: 48_000, channelCount: 1, commonFormat: .pcmFormatFloat32,
              isInterleaved: false, chunks: [.init(frameCount: 480, planes: [Data(count: 1920)])])
    }

    func testMultipartUploadAndUnicodeTranscript() async throws {
        let client = OpenAITranscriber { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-fake-test")
            let body = try XCTUnwrap(request.httpBody)
            let string = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(string.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
            XCTAssertTrue(string.contains("filename=\"recording.wav\""))
            XCTAssertTrue(string.contains("Content-Type: audio/wav\r\n\r\nRIFF"))
            return (Data("{\"text\":\"  Hello, 世界!  \"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let text = try await client.transcribe(recording, apiKey: "sk-fake-test")
        XCTAssertEqual(text, "Hello, 世界!")
    }

    func testAPIKeyValidationUsesSilentAudioAndAcceptsEmptyTranscript() async throws {
        let client = OpenAITranscriber { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-fake-validation")
            let body = try XCTUnwrap(request.httpBody)
            let marker = Data("RIFF".utf8)
            let range = try XCTUnwrap(body.range(of: marker))
            // Standard 44-byte WAV header, followed by exactly 32000 silent bytes.
            let start = range.lowerBound + 44
            XCTAssertEqual(body.subdata(in: start..<(start + 32000)), Data(count: 32000))
            return (Data("{\"text\":\"\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await client.validateAPIKey("sk-fake-validation")
    }

    func testAPIKeyValidationRejectsBillingAndInvalidKeyErrors() async {
        for (status, code, type) in [(401, "invalid_api_key", "invalid_request_error"),
                                    (429, "credit_balance_exhausted", "insufficient_quota"),
                                    (429, "project_spend_limit_exceeded", "insufficient_quota"),
                                    (429, "new_quota_code", "insufficient_quota")] {
            let client = OpenAITranscriber { request in
                let json = "{\"error\":{\"code\":\"\(code)\",\"type\":\"\(type)\"}}"
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do { try await client.validateAPIKey("sk-fake"); XCTFail("Expected validation failure") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains(status == 401 ? "API key" : "credits"))
            }
        }
    }

    func testHTTPFailuresAreHumanReadableAndDoNotExposeServerContent() async {
        for status in [400, 401, 403, 413, 429, 500] {
            let client = OpenAITranscriber { request in
                (Data("{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"private-server-detail\"}}".utf8),
                 HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do {
                _ = try await client.transcribe(recording, apiKey: "sk-fake-test")
                XCTFail("Expected HTTP failure")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("private-server-detail"))
                XCTAssertFalse(error.localizedDescription.contains("sk-fake-test"))
                if status == 429 { XCTAssertTrue(error.localizedDescription.contains("credits")) }
                if status == 401 { XCTAssertTrue(error.localizedDescription.contains("API key")) }
            }
        }
    }

    func testMalformedResponsesAreRejected() async {
        for json in ["not json", "{}"] {
            let client = OpenAITranscriber { request in
                (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await client.transcribe(recording, apiKey: "fake"); XCTFail("Expected invalid response") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testNoSpeechReturnsEmptyTranscriptWithoutError() async throws {
        for text in ["", "   "] {
            let client = OpenAITranscriber { request in
                (Data("{\"text\":\"\(text)\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let result = try await client.transcribe(recording, apiKey: "fake")
            XCTAssertEqual(result, "")
        }
    }

    func testNetworkTimeoutAndCancellation() async {
        for code in [URLError.Code.timedOut, .notConnectedToInternet, .cancelled] {
            let client = OpenAITranscriber { _ in throw URLError(code) }
            do { _ = try await client.transcribe(recording, apiKey: "fake"); XCTFail("Expected network failure") }
            catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error.localizedDescription.contains(code == .timedOut ? "timed out" : "internet")) }
            }
        }
    }
}
