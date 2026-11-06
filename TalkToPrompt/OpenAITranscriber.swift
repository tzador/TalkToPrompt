import Foundation

protocol AudioTranscribing: Sendable {
    func transcribe(_ recording: MicrophoneRecording, apiKey: String, language: String?) async throws -> String
}

/// Uploads an in-memory WAV; neither audio nor credentials are persisted by the client.
struct OpenAITranscriber: AudioTranscribing {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport

    init(transport: Transport? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        self.transport = transport ?? { try await session.data(for: $0) }
    }

    func transcribe(_ recording: MicrophoneRecording, apiKey: String, language: String? = nil) async throws -> String {
        try await requestTranscript(recording, apiKey: apiKey, language: language)
    }

    /// Checks the actual transcription endpoint, including model access and quota.
    /// Silence may legitimately return an empty transcript; HTTP success is enough.
    func validateAPIKey(_ key: String) async throws {
        let silence = MicrophoneRecording(
            sampleRate: 16_000, channelCount: 1, commonFormat: .pcmFormatInt16,
            isInterleaved: true, chunks: [.init(frameCount: 16_000, planes: [Data(count: 32_000)])]
        )
        _ = try await requestTranscript(silence, apiKey: key)
    }

    private func requestTranscript(_ recording: MicrophoneRecording, apiKey: String, language: String? = nil) async throws -> String {
        // Reject oversized PCM before allocating another copy for encoding/upload.
        guard recording.chunks.reduce(UInt64(44), { total, chunk in
            total + chunk.planes.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        }) < 25_000_000 else { throw TranscriptionError.tooLarge }
        let encoding = Task.detached(priority: .userInitiated) { try recording.makeWaveData() }
        let wave = try await withTaskCancellationHandler {
            try await encoding.value
        } onCancel: { encoding.cancel() }
        try Task.checkCancellation()
        let boundary = "TalkToPrompt-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n")
        if let language = TranscriptionLanguage.validated(language) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"languages[]\"\r\n\r\n\(language)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wave)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TranscriptionError.network(error.code == .timedOut)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(APIError.self, from: data))?.error
            let quotaCodes: Set<String> = ["insufficient_quota", "credit_balance_exhausted",
                "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "organization_usage_limit_exceeded"]
            let quota = detail?.type == "insufficient_quota" || quotaCodes.contains(detail?.code ?? "")
            throw TranscriptionError.rejected(http.statusCode, quota)
        }
        guard let result = try? JSONDecoder().decode(Transcript.self, from: data) else {
            throw TranscriptionError.invalidResponse
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Transcript: Decodable { let text: String }
    private struct APIError: Decodable {
        struct Detail: Decodable { let code: String?; let type: String? }
        let error: Detail
    }

    enum TranscriptionError: LocalizedError {
        case tooLarge, invalidResponse, network(Bool), rejected(Int, Bool)
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "This recording is too large to transcribe. Please try a shorter recording (under 25 MB)."
            case .invalidResponse: return "OpenAI returned a response that could not be read. Please try again."
            case .network(true): return "The transcription request timed out. Check your connection and try again."
            case .network(false): return "Could not connect to OpenAI. Check your internet connection and try again."
            case .rejected(401, _): return "OpenAI rejected the API key. Clear it and enter a valid key in TalkToPrompt."
            case .rejected(403, _): return "Your OpenAI account does not have access to transcription. Check your project's permissions and model access."
            case .rejected(429, true): return "Your OpenAI API account has insufficient credits or has reached its spending limit. Check billing and usage limits."
            case .rejected(429, false): return "OpenAI is receiving too many requests. Please wait a moment and try again."
            case .rejected(413, _): return "This recording is too large for OpenAI. Please try a shorter recording."
            case .rejected(let status, _) where status >= 500: return "OpenAI is temporarily unavailable. Please try again shortly."
            case .rejected(let status, _): return "OpenAI could not transcribe this recording (HTTP \(status)). Please try again or check your project's transcription model access."
            }
        }
    }
}
