import AVFoundation

@MainActor
final class BeepPlayer {
    enum Tone: CaseIterable, Hashable {
        case pressed
        case released

        var startFrequency: Double { self == .pressed ? 440 : 880 }
        var endFrequency: Double { self == .pressed ? 880 : 440 }
    }

    private var players: [Tone: AVAudioPlayer] = [:]

    func play(_ tone: Tone = .pressed) throws {
        if players[tone] == nil {
            let player = try AVAudioPlayer(data: Self.makeWaveData(tone: tone))
            player.prepareToPlay()
            players[tone] = player
        }

        // Each transition gets its own tone, even if the other tone is still playing.
        let player = players[tone]!
        player.currentTime = 0
        guard player.play() else {
            throw NSError(
                domain: "TalkToPrompt.Audio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The audio output could not start."]
            )
        }
    }

    /// A 222 ms linear sine sweep in mono, 16-bit PCM at 48 kHz.
    /// The raised-cosine volume envelope is silent at both ends and peaks halfway.
    static func makeWaveData(tone: Tone = .pressed) -> Data {
        let sampleRate = 48_000
        let sampleCount = 10_656 // Exactly 222 ms at 48 kHz.
        let duration = Double(sampleCount) / Double(sampleRate)
        let sweepRate = (tone.endFrequency - tone.startFrequency) / duration
        let audioByteCount = sampleCount * MemoryLayout<Int16>.size
        var data = Data()

        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + audioByteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)) // PCM format chunk size
        append(UInt16(1)) // Linear PCM
        append(UInt16(1)) // Mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)) // Bytes per second
        append(UInt16(2)) // Block alignment
        append(UInt16(16)) // Bits per sample
        data.append(contentsOf: "data".utf8)
        append(UInt32(audioByteCount))

        for index in 0..<sampleCount {
            let progress = Double(index) / Double(sampleCount - 1)
            let envelope = volumeEnvelope(progress: progress)
            let time = Double(index) / Double(sampleRate)
            // Integrate the changing frequency to keep the phase continuous
            // and make the audible pitch follow the requested sweep exactly.
            let phase = 2.0 * .pi * (tone.startFrequency * time + 0.5 * sweepRate * time * time)
            let sample = Int16(sin(phase) * envelope * 0.25 * Double(Int16.max))
            append(sample)
        }
        return data
    }

    /// One complete 0 → 1 → 0 cycle, with zero slope at the silent endpoints.
    static func volumeEnvelope(progress: Double) -> Double {
        let progress = min(1.0, max(0.0, progress))
        return (1.0 - cos(2.0 * .pi * progress)) / 2.0
    }
}
