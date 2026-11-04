import AppKit
import Foundation

@MainActor
protocol VoiceSessionOverlay: AnyObject {
    func show()
    func setMessage(_ message: String?)
    func hide(completion: (() -> Void)?)
    func hideImmediately()
}

/// Owns one hold → transcription → paste → close session. New holds cannot interrupt it.
@MainActor
final class VoiceSessionController {
    enum Phase: Equatable { case idle, missingAPIKey, preparing, listening, transcribing, translating, closing }
    private(set) var phase: Phase = .idle
    private let microphone: MicrophoneRecordingSession
    private let overlay: VoiceSessionOverlay
    private let transcriber: AudioTranscribing
    private let translator: TextTranslating
    private let language: DictationLanguageModel?
    private var targetLanguage: TranslationLanguage?
    private let loadAPIKey: () throws -> String?
    private let insertText: (String) async throws -> Void
    private let restoreClipboard: () -> Void
    private var apiKey: String?
    private let now: () -> TimeInterval
    private let onBegin: () -> Void
    private let onExit: () -> Void
    private let onError: (String) -> Void
    private var generation = UUID()
    private var recordingStartedAt: TimeInterval = 0
    private var timer: Timer?
    private var transcriptionTask: Task<Void, Never>?

    init(
        microphone: MicrophoneRecordingSession,
        overlay: VoiceSessionOverlay,
        transcriber: AudioTranscribing,
        loadAPIKey: @escaping () throws -> String?,
        insertText: @escaping (String) async throws -> Void,
        restoreClipboard: @escaping () -> Void = {},
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onBegin: @escaping () -> Void = {},
        onExit: @escaping () -> Void = {},
        onError: @escaping (String) -> Void = { _ in },
        language: DictationLanguageModel? = nil,
        translator: TextTranslating = OpenAITranslator()
    ) {
        self.microphone = microphone
        self.overlay = overlay
        self.transcriber = transcriber
        self.translator = translator
        self.language = language
        self.loadAPIKey = loadAPIKey
        self.insertText = insertText
        self.restoreClipboard = restoreClipboard
        self.now = now
        self.onBegin = onBegin
        self.onExit = onExit
        self.onError = onError
        microphone.onPermissionPrompt = { [weak self] in self?.overlay.hideImmediately() }
        microphone.onFirstAudio = { [weak self] in self?.audioStarted() }
        microphone.onFailure = { [weak self] in self?.close() }
    }

    @discardableResult
    func begin() -> Bool {
        guard phase == .idle else { return false }
        generation = UUID()
        targetLanguage = language?.activeLanguage
        phase = .preparing
        overlay.setMessage(nil)
        overlay.show()
        do {
            apiKey = try loadAPIKey()
            guard let apiKey, !apiKey.isEmpty else {
                phase = .missingAPIKey
                overlay.setMessage("No OpenAI API key provided")
                return true
            }
        } catch {
            close(error: error.localizedDescription)
            return true
        }
        microphone.begin()
        onBegin()
        return true
    }

    func finish() {
        if phase == .missingAPIKey { close(); return }
        guard phase == .preparing || phase == .listening else { return }
        phase = .transcribing
        stopTimer()
        overlay.setMessage("Transcribing...")
        let id = generation
        let stopped = microphone.finish()
        transcriptionTask = Task { @MainActor [weak self] in
            let recording = await stopped?.value
            guard let self, self.generation == id, !Task.isCancelled else { return }
            guard let recording, recording.frameCount > 0, let key = self.apiKey else { self.close(); return }
            do {
                let text = try await self.transcriber.transcribe(recording, apiKey: key)
                guard self.generation == id, !Task.isCancelled else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.close()
                    return
                }
                if self.language?.handleCommand(text) == true {
                    self.overlay.setMessage("Language: \(self.language?.displayName ?? "Auto")")
                    self.close()
                    return
                }
                let output: String
                if let target = self.targetLanguage {
                    self.phase = .translating
                    self.overlay.setMessage("Translating...")
                    output = try await self.translator.translate(text, to: target, apiKey: key)
                    guard self.generation == id, !Task.isCancelled else { return }
                } else { output = text }
                try await self.insertText(output)
                guard self.generation == id, !Task.isCancelled else { return }
                self.close()
            } catch {
                guard self.generation == id, !Task.isCancelled else { return }
                self.close(error: error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard phase != .idle && phase != .closing else { return }
        close()
    }

    func stopImmediately() {
        generation = UUID()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        microphone.finish()
        apiKey = nil
        targetLanguage = nil
        restoreClipboard()
        stopTimer()
        overlay.hideImmediately()
        phase = .idle
    }

    func updateStatus() {
        switch phase {
        case .listening:
            overlay.setMessage(message("Listening", elapsed: now() - recordingStartedAt))
        default: break
        }
    }

    private func audioStarted() {
        guard phase == .preparing else { return }
        recordingStartedAt = now()
        phase = .listening
        overlay.show()
        updateStatus()
        startTimer()
    }

    private func close(error: String? = nil) {
        guard phase != .idle && phase != .closing else { return }
        generation = UUID()
        phase = .closing
        transcriptionTask?.cancel()
        transcriptionTask = nil
        microphone.finish()
        apiKey = nil
        targetLanguage = nil
        restoreClipboard()
        stopTimer()
        onExit()
        let id = generation
        overlay.hide { [weak self] in
            guard let self, self.generation == id, self.phase == .closing else { return }
            self.phase = .idle
            if let error { self.onError(error) }
        }
    }

    private func message(_ verb: String, elapsed: TimeInterval) -> String {
        let seconds = Int(max(0, elapsed))
        return "\(verb)... \(seconds) \(seconds == 1 ? "second" : "seconds")"
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatus() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
