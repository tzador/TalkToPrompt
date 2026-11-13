import AVFoundation
import Foundation

struct RecordingBufferUsage: Equatable, Sendable {
    static let headerBytes = 44
    static let warningBytes = 20_000_000
    static let maximumBytes = 24_000_000
    static let bytesPerSecond = 32_000
    static let warningSeconds: TimeInterval = 5 * 60
    static let maximumSeconds: TimeInterval = 6 * 60
    static let maximumRecordingBytes = headerBytes + Int(maximumSeconds) * bytesPerSecond
    let byteCount: Int
    var elapsedSeconds: TimeInterval = 0

    var fraction: Double { min(1, max(0, Double(byteCount) / Double(Self.maximumBytes))) }
    var isWarning: Bool { byteCount >= Self.warningBytes || elapsedSeconds >= Self.warningSeconds }
    var isFull: Bool { byteCount >= Self.maximumBytes || elapsedSeconds >= Self.maximumSeconds }
    var remainingSeconds: Int {
        min(max(0, Self.maximumBytes - byteCount) / Self.bytesPerSecond,
            Int(max(0, Self.maximumSeconds - elapsedSeconds)))
    }
    static let empty = Self(byteCount: headerBytes)
}

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
    private var dataByteCount = 0
    private let maximumWaveBytes: Int?
    private let bytesPerFrame: Int

    init(format: AVAudioFormat, maximumWaveBytes: Int? = nil) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormat = format.commonFormat
        isInterleaved = format.isInterleaved
        self.maximumWaveBytes = maximumWaveBytes
        bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            * (format.isInterleaved ? 1 : Int(format.channelCount))
    }

    var waveByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return RecordingBufferUsage.headerBytes + dataByteCount
    }

    /// Returns true only for the first captured chunk.
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.frameLength > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard acceptingAudio else { return false }
        let availableFrames = maximumWaveBytes.map {
            max(0, $0 - RecordingBufferUsage.headerBytes - dataByteCount) / bytesPerFrame
        } ?? Int(buffer.frameLength)
        let frames = min(Int(buffer.frameLength), availableFrames)
        guard frames > 0 else { acceptingAudio = false; return false }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var planes: [Data] = []
        for audioBuffer in buffers {
            guard let bytes = audioBuffer.mData else { return false }
            let planeBytes = frames * bytesPerFrame / (isInterleaved ? 1 : Int(channelCount))
            planes.append(Data(bytes: bytes, count: planeBytes))
        }
        let first = chunks.isEmpty
        chunks.append(.init(frameCount: UInt32(frames), planes: planes))
        dataByteCount += frames * bytesPerFrame
        if let maximumWaveBytes, dataByteCount + RecordingBufferUsage.headerBytes >= maximumWaveBytes {
            acceptingAudio = false
        }
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

/// Resamples each tap buffer immediately; only bounded 16 kHz mono Int16 PCM is retained.
/// The lock also serializes converter finalization with the last audio callback.
final class PCMRecordingCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let audio: InMemoryAudioCapture
    private let maximumWaveBytes: Int
    private var finished = false
    private var started = false
    private var full = false
    static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    }

    init(inputFormat: AVAudioFormat, maximumWaveBytes: Int = RecordingBufferUsage.maximumRecordingBytes) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.format) else {
            throw MicrophoneRecorder.RecordingError.conversionFailed
        }
        converter.downmix = true
        self.converter = converter
        self.maximumWaveBytes = maximumWaveBytes
        audio = InMemoryAudioCapture(format: Self.format, maximumWaveBytes: maximumWaveBytes)
    }

    func append(_ buffer: AVAudioPCMBuffer) throws -> (first: Bool, usage: RecordingBufferUsage)? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !full, buffer.frameLength > 0 else { return nil }
        try convert(buffer)
        let byteCount = audio.waveByteCount
        let usage = RecordingBufferUsage(byteCount: byteCount,
            elapsedSeconds: Double(byteCount - RecordingBufferUsage.headerBytes) / Double(RecordingBufferUsage.bytesPerSecond))
        guard usage.byteCount > RecordingBufferUsage.headerBytes else { return nil }
        let first = !started
        started = true
        full = usage.byteCount >= maximumWaveBytes
        return (first, usage)
    }

    func finish() -> MicrophoneRecording {
        lock.lock()
        defer { lock.unlock() }
        if !finished, !full { try? convert(nil) }
        finished = true
        return audio.finish()
    }

    private func convert(_ input: AVAudioPCMBuffer?) throws {
        var suppliedInput = false
        // Fixed output capacity bounds temporary memory even for a large input buffer.
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 4096) else {
            throw MicrophoneRecorder.RecordingError.conversionFailed
        }
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let input, !suppliedInput {
                    suppliedInput = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error { throw error ?? MicrophoneRecorder.RecordingError.conversionFailed }
            if output.frameLength > 0 { _ = audio.append(output) }
            if audio.waveByteCount >= maximumWaveBytes || status != .haveData { return }
        }
    }
}

protocol MicrophoneCapturing: Sendable {
    func start(
        id: UUID,
        onFirstAudio: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (String) -> Void,
        onIntensities: @escaping @Sendable ([Float]) -> Void,
        onBufferUsage: @escaping @Sendable (RecordingBufferUsage) -> Void
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
        let audio: PCMRecordingCapture
        let observer: NSObjectProtocol
    }
    private var active: ActiveCapture?
    private var completed: [UUID: MicrophoneRecording] = [:]
    private var cancelledBeforeStart: Set<UUID> = []

    func start(
        id: UUID,
        onFirstAudio: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (String) -> Void,
        onIntensities: @escaping @Sendable ([Float]) -> Void = { _ in },
        onBufferUsage: @escaping @Sendable (RecordingBufferUsage) -> Void = { _ in }
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
        let audio = try PCMRecordingCapture(inputFormat: format)
        let intensity = AudioIntensityAnalyzer(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 256, format: format) { buffer, _ in
            do {
                guard let update = try audio.append(buffer) else { return }
                if update.first { onFirstAudio() }
                onBufferUsage(update.usage)
                let values = intensity.consume(buffer)
                if !values.isEmpty { onIntensities(values) }
            } catch {
                onFailure("The microphone audio could not be converted. Please try again.")
            }
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
        case noInputDevice, conversionFailed
        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No working microphone is available."
            case .conversionFailed: return "The microphone audio could not be converted to 16 kHz mono PCM."
            }
        }
    }
}
