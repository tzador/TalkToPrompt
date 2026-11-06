import AVFoundation
import Foundation

struct MicrophoneRecording: Sendable {
    struct Chunk: Sendable {
        let frameCount: UInt32
        let planes: [Data]
    }

    let sampleRate: Double
    let channelCount: UInt32
    let commonFormat: AVAudioCommonFormat
    let isInterleaved: Bool
    let chunks: [Chunk]

    var frameCount: UInt64 { chunks.reduce(0) { $0 + UInt64($1.frameCount) } }
    var duration: TimeInterval { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}

/// Copies the audio callback's reusable buffers into owned, memory-only data.
/// Only the short append/seal operations share a lock with the audio thread.
final class InMemoryAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleRate: Double
    private let channelCount: UInt32
    private let commonFormat: AVAudioCommonFormat
    private let isInterleaved: Bool
    private var chunks: [MicrophoneRecording.Chunk] = []
    private var acceptingAudio = true

    init(format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormat = format.commonFormat
        isInterleaved = format.isInterleaved
    }

    /// Returns true only for the first captured chunk.
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.frameLength > 0 else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var planes: [Data] = []
        for audioBuffer in buffers {
            guard let bytes = audioBuffer.mData else { return false }
            planes.append(Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize)))
        }
        lock.lock()
        defer { lock.unlock() }
        guard acceptingAudio else { return false }
        let first = chunks.isEmpty
        chunks.append(.init(frameCount: buffer.frameLength, planes: planes))
        return first
    }

    func finish() -> MicrophoneRecording {
        lock.lock()
        defer { lock.unlock() }
        acceptingAudio = false
        let recording = MicrophoneRecording(
            sampleRate: sampleRate, channelCount: channelCount,
            commonFormat: commonFormat, isInterleaved: isInterleaved, chunks: chunks
        )
        chunks.removeAll()
        return recording
    }
}

protocol MicrophoneCapturing: Sendable {
    func start(
        id: UUID,
        onFirstAudio: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (String) -> Void,
        onIntensities: @escaping @Sendable ([Float]) -> Void
    ) async throws
    func stop(id: UUID) async -> MicrophoneRecording?
}

/// Serializes hardware operations off the main thread, so opening the input
/// device cannot block the overlay's fade or the keyboard event callback.
actor MicrophoneRecorder: MicrophoneCapturing {
    private struct ActiveCapture {
        let id: UUID
        let engine: AVAudioEngine
        let input: AVAudioInputNode
        let audio: InMemoryAudioCapture
        let observer: NSObjectProtocol
    }
    private var active: ActiveCapture?
    private var completed: [UUID: MicrophoneRecording] = [:]
    private var cancelledBeforeStart: Set<UUID> = []

    func start(
        id: UUID,
        onFirstAudio: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (String) -> Void,
        onIntensities: @escaping @Sendable ([Float]) -> Void = { _ in }
    ) throws {
        if cancelledBeforeStart.remove(id) != nil { throw CancellationError() }
        if let active {
            completed[active.id] = stopActiveCapture()
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            engine.stop()
            throw RecordingError.noInputDevice
        }
        let audio = InMemoryAudioCapture(format: format)
        let intensity = AudioIntensityAnalyzer(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 256, format: format) { buffer, _ in
            if audio.append(buffer) { onFirstAudio() }
            let values = intensity.consume(buffer)
            if !values.isEmpty { onIntensities(values) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            throw error
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { await self?.inputConfigurationChanged(id: id, onFailure: onFailure) }
        }
        active = ActiveCapture(id: id, engine: engine, input: input, audio: audio, observer: observer)
    }

    func stop(id: UUID) -> MicrophoneRecording? {
        if active?.id == id { return stopActiveCapture() }
        if let recording = completed.removeValue(forKey: id) { return recording }
        // A release can reach this actor before a queued hardware start.
        cancelledBeforeStart.insert(id)
        return nil
    }

    private func stopActiveCapture() -> MicrophoneRecording? {
        guard let capture = active else { return nil }
        active = nil
        NotificationCenter.default.removeObserver(capture.observer)
        capture.engine.stop()
        capture.input.removeTap(onBus: 0)
        capture.engine.reset()
        // Neither engine nor input node is retained after this method returns.
        return capture.audio.finish()
    }

    private func inputConfigurationChanged(id: UUID, onFailure: @Sendable (String) -> Void) {
        guard active?.id == id else { return }
        completed[id] = stopActiveCapture()
        onFailure("The microphone configuration changed. Release both Shift keys and try again.")
    }

    enum RecordingError: LocalizedError {
        case noInputDevice
        var errorDescription: String? { "No working microphone is available." }
    }
}
