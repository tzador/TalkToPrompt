import AVFoundation

/// One instance belongs to one serial audio tap. Partial windows carry across
/// buffers; every complete 10 ms slice is emitted, even in a larger tap buffer.
final class AudioIntensityAnalyzer: @unchecked Sendable {
    static let interval: TimeInterval = 0.01
    private let framesPerWindow: Double
    private var framesUntilBoundary: Double
    private var frameCount = 0
    private var totalVolume: Double = 0

    init(sampleRate: Double) {
        framesPerWindow = sampleRate * Self.interval
        framesUntilBoundary = framesPerWindow
    }

    /// Chronological normalized intensities (oldest first). Sum absolute sample
    /// volumes across all channels, then normalize by the window's sample count.
    /// This avoids phase cancellation and keeps levels consistent across devices.
    func consume(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard framesPerWindow.isFinite, framesPerWindow >= 1,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData, buffer.format.channelCount > 0 else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        var intensities: [Float] = []
        for frame in 0..<Int(buffer.frameLength) {
            var volume: Double = 0
            for channel in 0..<channelCount {
                let sample = buffer.format.isInterleaved
                    ? channels[0][frame * channelCount + channel] : channels[channel][frame]
                if sample.isFinite { volume += Double(abs(sample)) }
            }
            totalVolume += volume / Double(channelCount)
            frameCount += 1
            framesUntilBoundary -= 1
            if framesUntilBoundary <= 0 {
                let meanVolume = totalVolume / Double(frameCount)
                let decibels = 20 * log10(max(1e-6, meanVolume))
                intensities.append(Float(min(1, max(0, (decibels + 60) / 48))))
                totalVolume = 0
                frameCount = 0
                // Retain fractional frames for rates such as 22,050 Hz.
                framesUntilBoundary += framesPerWindow
            }
        }
        return intensities
    }
}
