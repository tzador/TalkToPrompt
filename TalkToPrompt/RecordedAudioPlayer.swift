import AVFoundation
import Foundation

@MainActor
protocol RecordingPlaying: AnyObject {
    var currentTime: TimeInterval { get }
    func play(_ recording: MicrophoneRecording, onFinished: @escaping (String?) -> Void) async throws
    func stop()
}

/// Plays captured PCM using an in-memory WAV. Never creates a file or input node.
@MainActor
final class RecordedAudioPlayer: NSObject, RecordingPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var encodingTask: Task<Data, Error>?
    private var generation = UUID()
    private var onFinished: ((String?) -> Void)?

    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    func play(_ recording: MicrophoneRecording, onFinished: @escaping (String?) -> Void) async throws {
        stop()
        let id = generation
        let encoding = Task.detached(priority: .userInitiated) { try recording.makeWaveData() }
        encodingTask = encoding
        let data = try await withTaskCancellationHandler {
            try await encoding.value
        } onCancel: { encoding.cancel() }
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        encodingTask = nil
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        self.onFinished = onFinished
        guard player.play() else {
            stop()
            throw PlaybackError.cannotPlay
        }
    }

    func stop() {
        generation = UUID()
        encodingTask?.cancel()
        encodingTask = nil
        player?.stop()
        player?.delegate = nil
        player = nil
        onFinished = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.complete(player: player, error: flag ? nil : "Recorded audio playback did not complete.")
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "The recorded audio could not be decoded."
        Task { @MainActor [weak self] in self?.complete(player: player, error: message) }
    }

    private func complete(player: AVAudioPlayer, error: String?) {
        guard self.player === player else { return }
        let completion = onFinished
        stop()
        completion?(error)
    }

    enum PlaybackError: LocalizedError {
        case cannotPlay
        case invalidRecording
        var errorDescription: String? {
            switch self {
            case .cannotPlay: return "The recorded audio could not start playing."
            case .invalidRecording: return "The recorded audio has an unsupported or invalid PCM format."
            }
        }
    }
}

extension MicrophoneRecording {
    /// Interleaves native PCM planes into a standard WAV payload in memory.
    func makeWaveData() throws -> Data {
        let bytesPerSample: Int
        let formatCode: UInt16
        switch commonFormat {
        case .pcmFormatFloat32: bytesPerSample = 4; formatCode = 3
        case .pcmFormatFloat64: bytesPerSample = 8; formatCode = 3
        case .pcmFormatInt16: bytesPerSample = 2; formatCode = 1
        case .pcmFormatInt32: bytesPerSample = 4; formatCode = 1
        default: throw RecordedAudioPlayer.PlaybackError.invalidRecording
        }
        let byteCount = frameCount * UInt64(channelCount) * UInt64(bytesPerSample)
        guard frameCount > 0, channelCount > 0, channelCount <= UInt16.max,
              sampleRate.isFinite, sampleRate > 0, sampleRate <= Double(UInt32.max),
              byteCount <= UInt32.max - 36 else {
            throw RecordedAudioPlayer.PlaybackError.invalidRecording
        }
        let channels = Int(channelCount)
        let blockAlignment = channels * bytesPerSample
        guard blockAlignment <= UInt16.max,
              sampleRate * Double(blockAlignment) <= Double(UInt32.max) else {
            throw RecordedAudioPlayer.PlaybackError.invalidRecording
        }
        var data = Data()
        data.reserveCapacity(44 + Int(byteCount))
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + byteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(formatCode)
        append(UInt16(channelCount))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * Double(blockAlignment)))
        append(UInt16(blockAlignment))
        append(UInt16(bytesPerSample * 8))
        data.append(contentsOf: "data".utf8)
        append(UInt32(byteCount))
        data.count = 44 + Int(byteCount)
        try data.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            var offset = 44
            for chunk in chunks {
                try Task.checkCancellation()
                let frames = Int(chunk.frameCount)
                if frames == 0 { continue }
                let expectedPlanes = isInterleaved ? 1 : channels
                let planeBytes = frames * bytesPerSample * (isInterleaved ? channels : 1)
                guard chunk.planes.count == expectedPlanes,
                      chunk.planes.allSatisfy({ $0.count == planeBytes }) else {
                    throw RecordedAudioPlayer.PlaybackError.invalidRecording
                }
                if isInterleaved {
                    chunk.planes[0].withUnsafeBytes { source in
                        destination.baseAddress!.advanced(by: offset).copyMemory(from: source.baseAddress!, byteCount: planeBytes)
                    }
                } else {
                    for channel in 0..<channels {
                        chunk.planes[channel].withUnsafeBytes { source in
                            for frame in 0..<frames {
                                destination.baseAddress!.advanced(by: offset + (frame * channels + channel) * bytesPerSample)
                                    .copyMemory(from: source.baseAddress!.advanced(by: frame * bytesPerSample), byteCount: bytesPerSample)
                            }
                        }
                    }
                }
                offset += frames * blockAlignment
            }
        }
        return data
    }
}
