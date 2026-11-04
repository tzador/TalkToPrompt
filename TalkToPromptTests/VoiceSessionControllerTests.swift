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

private actor SessionTranscriber: AudioTranscribing {
    var requests = 0
    var fail = false
    var pending: CheckedContinuation<String, Error>?
    func transcribe(_ recording: MicrophoneRecording, apiKey: String) async throws -> String {
        requests += 1
        if fail { throw OpenAITranscriber.TranscriptionError.rejected(401, false) }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete(text: String = "hello, world") { pending?.resume(returning: text); pending = nil }
    func setFailure() { fail = true }
}

private actor SessionTranslator: TextTranslating {
    var requests: [(String, TranslationLanguage)] = []
    var fail = false
    private var pending: CheckedContinuation<String, Error>?
    func translate(_ text: String, to language: TranslationLanguage, apiKey: String) async throws -> String {
        requests.append((text, language))
        if fail { throw OpenAITranslator.TranslationError.rejected(429, true) }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete(_ text: String) { pending?.resume(returning: text); pending = nil }
    func setFailure() { fail = true }
}

@MainActor
private final class VoiceFixture {
    let capture = SessionCapture()
    let overlay = SessionOverlay()
    let transcriber = SessionTranscriber()
    let translator = SessionTranslator()
    let language = DictationLanguageModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    var key: String? = "sk-test-only"
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
        language: language, translator: translator
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
    func testExplicitTranslationCommandsSwitchModeWithoutTranslatingOrPasting() async {
        for (command, expected) in [("Translate to Ukrainian.", "uk"), ("TRANSLATE TO SPANISH!", "es"), ("Don’t translate.", "auto"), ("No translation", "auto"), ("Translation off.", "auto"), ("Translation none", "auto")] {
            let f = VoiceFixture()
            f.language.handleCommand("Translate to German")
            await listen(f)
            f.voice.finish()
            await waitUntil { await f.transcriber.requests == 1 }
            await f.transcriber.complete(text: command)
            await waitUntil { f.voice.phase == .closing }
            XCTAssertEqual(f.language.activeLanguage?.code ?? "auto", expected)
            XCTAssertEqual(f.overlay.message, "Language: " + f.language.displayName)
            let translations = await f.translator.requests
            XCTAssertTrue(translations.isEmpty)
            XCTAssertTrue(f.pasted.isEmpty)
            f.overlay.completeFade()
            f.voice.stopImmediately()
        }
    }

    @MainActor
    func testTargetLanguageAddsTranslationBetweenTranscriptionAndPaste() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        f.language.handleCommand("Translate to Spanish")
        await listen(f)
        XCTAssertEqual(f.overlay.message, "Listening... 0 seconds")
        f.voice.finish()
        XCTAssertEqual(f.overlay.message, "Transcribing...")
        await waitUntil { await f.transcriber.requests == 1 }
        await f.transcriber.complete(text: "Hello, world")
        await waitUntil { await f.translator.requests.count == 1 }
        XCTAssertEqual(f.voice.phase, .translating)
        XCTAssertEqual(f.overlay.message, "Translating...")
        let request = await f.translator.requests[0]
        XCTAssertEqual(request.0, "Hello, world")
        XCTAssertEqual(request.1.code, "es")
        XCTAssertTrue(f.pasted.isEmpty)
        XCTAssertFalse(f.voice.begin())
        f.voice.finish() // Releasing an ignored chord cannot interrupt translation.
        await f.translator.complete("Hola, mundo")
        await waitUntil { f.voice.phase == .closing }
        XCTAssertEqual(f.pasted, ["Hola, mundo"])
        f.overlay.completeFade()
        XCTAssertTrue(f.errors.isEmpty)
    }

    @MainActor
    func testAutoModeDoesNotCallTranslation() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        await listen(f)
        f.voice.finish()
        await waitUntil { await f.transcriber.requests == 1 }
        await f.transcriber.complete(text: "Добрий день")
        await waitUntil { f.voice.phase == .closing }
        XCTAssertEqual(f.pasted, ["Добрий день"])
        let translations = await f.translator.requests
        XCTAssertTrue(translations.isEmpty)
    }

    @MainActor
    func testBareLanguageNamesAndAutoArePastedAsOrdinaryDictation() async {
        for text in ["Spanish.", "Greek", "Persian", "Ukrainian", "Auto"] {
            let f = VoiceFixture()
            await listen(f)
            f.voice.finish()
            await waitUntil { await f.transcriber.requests == 1 }
            await f.transcriber.complete(text: text)
            await waitUntil { f.voice.phase == .closing }
            XCTAssertEqual(f.pasted, [text])
            XCTAssertNil(f.language.activeLanguage)
            f.voice.stopImmediately()
        }
    }

    @MainActor
    func testTranslationFailureDoesNotPasteAndShowsErrorAfterFade() async {
        let f = VoiceFixture()
        defer { f.voice.stopImmediately() }
        f.language.handleCommand("Translate to Ukrainian")
        await f.translator.setFailure()
        await listen(f)
        f.voice.finish()
        await waitUntil { await f.transcriber.requests == 1 }
        await f.transcriber.complete()
        await waitUntil { f.voice.phase == .closing }
        XCTAssertTrue(f.pasted.isEmpty)
        XCTAssertTrue(f.errors.isEmpty)
        f.overlay.completeFade()
        XCTAssertTrue(f.errors.first?.contains("credits") == true)
    }

    @MainActor
    func testShutdownDuringTranslationPreventsLatePaste() async {
        let f = VoiceFixture()
        f.language.handleCommand("Translate to Spanish")
        await listen(f)
        f.voice.finish()
        await waitUntil { await f.transcriber.requests == 1 }
        await f.transcriber.complete()
        await waitUntil { await f.translator.requests.count == 1 }
        f.voice.stopImmediately()
        await f.translator.complete("Hola, mundo")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(f.pasted.isEmpty)
        XCTAssertTrue(f.errors.isEmpty)
        XCTAssertEqual(f.voice.phase, .idle)
        XCTAssertFalse(f.overlay.visible)
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
