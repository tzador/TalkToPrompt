import AVFoundation
import XCTest
@testable import TalkToPrompt

final class RecordedAudioPlayerTests: XCTestCase {
    private func bytes<T>(of values: [T]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    @MainActor
    func testFloatPCMCanBeDecodedFromInMemoryWAV() throws {
        let recording = MicrophoneRecording(
            sampleRate: 48_000, channelCount: 1, commonFormat: .pcmFormatFloat32, isInterleaved: false,
            chunks: [.init(frameCount: 480, planes: [bytes(of: [Float](repeating: 0.25, count: 480))])]
        )
        let data = try recording.makeWaveData()
        let player = try AVAudioPlayer(data: data)
        XCTAssertEqual(player.duration, 0.01, accuracy: 0.000001)
        XCTAssertEqual(player.numberOfChannels, 1)
        XCTAssertEqual(data.count, 44 + 480 * 4)
        XCTAssertEqual(data.dropFirst(44).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, 0.25)
    }

    @MainActor
    func testPlanarStereoIsInterleavedInCorrectChannelOrder() throws {
        let recording = MicrophoneRecording(
            sampleRate: 48_000, channelCount: 2, commonFormat: .pcmFormatInt16, isInterleaved: false,
            chunks: [.init(frameCount: 2, planes: [bytes(of: [Int16(100), 200]), bytes(of: [Int16(-100), -200])])]
        )
        let data = try recording.makeWaveData()
        XCTAssertEqual(Data(data.dropFirst(44)), bytes(of: [Int16(100), -100, 200, -200]))
        XCTAssertEqual(try AVAudioPlayer(data: data).numberOfChannels, 2)
    }

    func testInterleavedChunksKeepTheirOrder() throws {
        let first = bytes(of: [Int16(1), 2, 3, 4])
        let second = bytes(of: [Int16(5), 6, 7, 8])
        let recording = MicrophoneRecording(
            sampleRate: 48_000, channelCount: 2, commonFormat: .pcmFormatInt16, isInterleaved: true,
            chunks: [.init(frameCount: 2, planes: [first]), .init(frameCount: 2, planes: [second])]
        )
        XCTAssertEqual(Data(try recording.makeWaveData().dropFirst(44)), first + second)
    }

    @MainActor
    func testFloat64AndInt32PCMCanAlsoBeDecoded() throws {
        for (format, payload) in [
            (AVAudioCommonFormat.pcmFormatFloat64, bytes(of: [Double](repeating: 0.25, count: 480))),
            (AVAudioCommonFormat.pcmFormatInt32, bytes(of: [Int32](repeating: 16_384, count: 480)))
        ] {
            let recording = MicrophoneRecording(
                sampleRate: 48_000, channelCount: 1, commonFormat: format, isInterleaved: false,
                chunks: [.init(frameCount: 480, planes: [payload])]
            )
            let player = try AVAudioPlayer(data: recording.makeWaveData())
            XCTAssertEqual(player.duration, 0.01, accuracy: 0.000001)
        }
    }

    func testInvalidPCMDoesNotReadOutsideTheProvidedPlanes() {
        let recording = MicrophoneRecording(
            sampleRate: 48_000, channelCount: 2, commonFormat: .pcmFormatFloat32, isInterleaved: false,
            chunks: [.init(frameCount: 480, planes: [Data(count: 4)])]
        )
        XCTAssertThrowsError(try recording.makeWaveData())
    }

    func testEmptyRecordingIsRejected() {
        let recording = MicrophoneRecording(
            sampleRate: 48_000, channelCount: 1, commonFormat: .pcmFormatFloat32, isInterleaved: false, chunks: []
        )
        XCTAssertThrowsError(try recording.makeWaveData())
    }

    func testCancelledWAVPreparationStopsBeforeEncodingAudio() async {
        let recording = MicrophoneRecording(
            sampleRate: 48_000, channelCount: 1, commonFormat: .pcmFormatFloat32, isInterleaved: false,
            chunks: [.init(frameCount: 480, planes: [Data(count: 1920)])]
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try recording.makeWaveData()
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
