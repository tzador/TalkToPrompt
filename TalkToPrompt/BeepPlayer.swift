import AVFoundation

@MainActor
final class BeepPlayer {
    enum Tone: Double, CaseIterable {
        case pressed = 440
        case released = 880
    }

    private var players: [Tone: AVAudioPlayer] = [:]

    func play(_ tone: Tone = .pressed) throws {
        if players[tone] == nil {
            let player = try AVAudioPlayer(data: Self.makeWaveData(frequency: tone.rawValue))
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

    /// One second of mono, 16-bit PCM audio at 44.1 kHz.
    /// A short fade at each edge prevents clicks without changing the tone.
    static func makeWaveData(frequency: Double = Tone.pressed.rawValue) -> Data {
        let sampleRate = 44_100
        let sampleCount = sampleRate
        let fadeSamples = 220
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
            let edgeDistance = min(index, sampleCount - 1 - index)
            let envelope = min(1.0, Double(edgeDistance) / Double(fadeSamples))
            let phase = 2.0 * Double.pi * frequency * Double(index) / Double(sampleRate)
            let sample = Int16(sin(phase) * envelope * 0.25 * Double(Int16.max))
            append(sample)
        }
        return data
    }
}
