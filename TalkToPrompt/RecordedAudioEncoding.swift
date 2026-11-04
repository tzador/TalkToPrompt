import AVFoundation
import Foundation

enum AudioEncodingError: LocalizedError {
    case invalidRecording
    var errorDescription: String? { "The recorded audio has an unsupported or invalid PCM format." }
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
        default: throw AudioEncodingError.invalidRecording
        }
        let byteCount = frameCount * UInt64(channelCount) * UInt64(bytesPerSample)
        guard frameCount > 0, channelCount > 0, channelCount <= UInt16.max,
              sampleRate.isFinite, sampleRate > 0, sampleRate <= Double(UInt32.max),
              byteCount <= UInt32.max - 36 else {
            throw AudioEncodingError.invalidRecording
        }
        let channels = Int(channelCount)
        let blockAlignment = channels * bytesPerSample
        guard blockAlignment <= UInt16.max,
              sampleRate * Double(blockAlignment) <= Double(UInt32.max) else {
            throw AudioEncodingError.invalidRecording
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
                    throw AudioEncodingError.invalidRecording
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
