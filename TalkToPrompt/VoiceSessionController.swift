import AppKit
import Foundation

@MainActor
protocol VoiceSessionOverlay: AnyObject {
    func show()
    func setMessage(_ message: String?)
    func hide(completion: (() -> Void)?)
    func hideImmediately()
}

/// Owns one hold → playback → close session. New holds cannot interrupt it.
@MainActor
final class VoiceSessionController {
    enum Phase: Equatable { case idle, preparing, listening, finishing, speaking, closing }
    private(set) var phase: Phase = .idle
    private let microphone: MicrophoneRecordingSession
    private let overlay: VoiceSessionOverlay
    private let player: RecordingPlaying
    private let now: () -> TimeInterval
    private let onBegin: () -> Void
    private let onExit: () -> Void
    private let onError: (String) -> Void
    private var generation = UUID()
    private var recordingStartedAt: TimeInterval = 0
    private var timer: Timer?
    private var playbackTask: Task<Void, Never>?

    init(
        microphone: MicrophoneRecordingSession,
        overlay: VoiceSessionOverlay,
        player: RecordingPlaying,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onBegin: @escaping () -> Void = {},
        onExit: @escaping () -> Void = {},
        onError: @escaping (String) -> Void = { _ in }
    ) {
        self.microphone = microphone
        self.overlay = overlay
        self.player = player
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
        phase = .preparing
        overlay.setMessage(nil)
        overlay.show()
        microphone.begin()
        onBegin()
        return true
    }

    func finish() {
        guard phase == .preparing || phase == .listening else { return }
        phase = .finishing
        stopTimer()
        overlay.setMessage("Speaking... 0 seconds")
        let id = generation
        let stopped = microphone.finish()
        playbackTask = Task { @MainActor [weak self] in
            let recording = await stopped?.value
            guard let self, self.generation == id, self.phase == .finishing, !Task.isCancelled else { return }
            guard let recording, recording.frameCount > 0 else { self.close(); return }
            do {
                try await self.player.play(recording) { [weak self] error in
                    guard let self, self.generation == id else { return }
                    if let error { self.onError(error) }
                    self.close()
                }
                guard self.generation == id, self.phase == .finishing, !Task.isCancelled else { return }
                self.phase = .speaking
                self.updateStatus()
                self.startTimer()
            } catch is CancellationError {
                // Cancellation invalidates the generation before stopping playback.
            } catch {
                guard self.generation == id else { return }
                self.onError(error.localizedDescription)
                self.close()
            }
        }
    }

    func cancel() {
        guard phase != .idle && phase != .closing else { return }
        close()
    }

    func stopImmediately() {
        generation = UUID()
        playbackTask?.cancel()
        playbackTask = nil
        microphone.finish()
        player.stop()
        stopTimer()
        overlay.hideImmediately()
        phase = .idle
    }

    func updateStatus() {
        switch phase {
        case .listening:
            overlay.setMessage(message("Listening", elapsed: now() - recordingStartedAt))
        case .speaking:
            overlay.setMessage(message("Speaking", elapsed: player.currentTime))
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

    private func close() {
        guard phase != .idle && phase != .closing else { return }
        generation = UUID()
        phase = .closing
        playbackTask?.cancel()
        playbackTask = nil
        microphone.finish()
        player.stop()
        stopTimer()
        onExit()
        let id = generation
        overlay.hide { [weak self] in
            guard let self, self.generation == id, self.phase == .closing else { return }
            self.phase = .idle
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
