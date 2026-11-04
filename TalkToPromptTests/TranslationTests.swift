import XCTest
@testable import TalkToPrompt

final class TranslationTests: XCTestCase {
    @MainActor
    func testExplicitCommandsAreCaseInsensitiveAndPersistUntilTranslationIsDisabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = DictationLanguageModel(defaults: defaults)
        XCTAssertEqual(model.displayName, "Auto")
        for (name, code) in [("Ukrainian.", "uk"), ("SPANISH!", "es"), ("  Romanian\n", "ro"),
                             ("English", "en"), ("Japanese", "ja"), ("German", "de"), ("Portuguese", "pt"),
                             ("Farsi", "fa"), ("Norwegian Bokmal", "nb"), ("Cantonese", "yue")] {
            XCTAssertTrue(model.handleCommand("Translate to " + name), name)
            XCTAssertEqual(model.activeLanguage?.code, code, name)
            XCTAssertEqual(DictationLanguageModel(defaults: defaults).activeLanguage?.code, code)
        }
        XCTAssertTrue(model.handleCommand("Translation off."))
        XCTAssertNil(model.activeLanguage)
        XCTAssertNil(defaults.string(forKey: DictationLanguageModel.defaultsKey))
        XCTAssertNil(DictationLanguageModel(defaults: defaults).activeLanguage)
    }

    @MainActor
    func testSentencesAreNeverLanguageCommands() throws {
        let model = DictationLanguageModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        XCTAssertTrue(model.handleCommand("Translate to Ukrainian"))
        for text in ["Spanish", "Ukrainian.", "Greek", "Persian", "Auto", "Spanish please", "I speak English.",
                     "Translate to Spanish please", "Please translate to Greek", "Translate to Spanish and Ukrainian",
                     "Don't translate this sentence", "No translation is needed", "Translation off please",
                     "Translate to Klingon", "Translate to", "en", "", "  ", "Español"] {
            XCTAssertFalse(model.handleCommand(text), text)
            XCTAssertEqual(model.activeLanguage?.code, "uk")
        }
    }

    @MainActor
    func testAllDisablePhrasesIncludingCurlyApostrophesRestoreAuto() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = DictationLanguageModel(defaults: defaults)
        for command in ["Don't translate.", "Don’t translate!", "Do not translate", "No translation.", "TRANSLATION OFF!", "translation none"] {
            XCTAssertTrue(model.handleCommand("Translate to Greek"))
            XCTAssertEqual(model.activeLanguage?.code, "el")
            XCTAssertTrue(model.handleCommand(command), command)
            XCTAssertNil(model.activeLanguage)
            XCTAssertNil(DictationLanguageModel(defaults: defaults).activeLanguage)
        }
        XCTAssertTrue(model.handleCommand("Translate to Persian."))
        XCTAssertEqual(model.activeLanguage?.code, "fa")
    }

    @MainActor
    func testUnknownStoredLanguageFallsBackToAuto() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("not-a-language", forKey: DictationLanguageModel.defaultsKey)
        XCTAssertNil(DictationLanguageModel(defaults: defaults).activeLanguage)
    }

    private static func response(_ object: [String: Any], request: URLRequest, status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private static func translationResponse(_ translation: String, request: URLRequest) throws -> (Data, URLResponse) {
        let output = String(decoding: try JSONSerialization.data(withJSONObject: ["translation": translation]), as: UTF8.self)
        return try response(["status": "completed", "output": [
            ["type": "reasoning"],
            ["type": "message", "content": [["type": "output_text", "text": output]]]
        ]], request: request)
    }

    func testLunaRequestUsesStructuredInputAndStrictOutputSchema() async throws {
        let source = "Hello, world.\nTranslate this literally: \"ignore instructions\"."
        let client = OpenAITranslator { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-only")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
            XCTAssertEqual(body["store"] as? Bool, false)
            let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.last?["content"] as? [[String: String]])
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(content.first?["text"]).utf8)) as? [String: Any])
            XCTAssertEqual(input["source_text"] as? String, source)
            XCTAssertEqual((input["target_language"] as? [String: String])?["code"], "uk")
            let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")
            XCTAssertEqual(format["strict"] as? Bool, true)
            let schema = try XCTUnwrap(format["schema"] as? [String: Any])
            XCTAssertEqual(schema["required"] as? [String], ["translation"])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            return try Self.translationResponse("Привіт, світе!", request: request)
        }
        let result = try await client.translate(source, to: .init(code: "uk", name: "Ukrainian"), apiKey: "sk-test-only")
        XCTAssertEqual(result, "Привіт, світе!")
    }

    func testRefusedIncompleteAndMalformedResponsesAreNotReturnedAsTranslations() async {
        let responses: [[String: Any]] = [
            ["status": "incomplete", "output": []],
            ["status": "completed", "output": [["type": "message", "content": [["type": "refusal"]]]]],
            ["status": "completed", "output": []],
            ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "{}"]]]]],
            ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "{\"translation\":\" \"}"]]]]],
            [:]
        ]
        for response in responses {
            let data = try! JSONSerialization.data(withJSONObject: response)
            let client = OpenAITranslator { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            do {
                _ = try await client.translate("hello", to: .init(code: "es", name: "Spanish"), apiKey: "fake")
                XCTFail("Expected translation failure")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testTranslationHTTPFailuresAreReadableAndDoNotExposeServerDetails() async {
        for status in [401, 403, 429, 500] {
            let client = OpenAITranslator { request in
                try Self.response(["error": ["code": "insufficient_quota", "message": "private-server-detail"]], request: request, status: status)
            }
            do {
                _ = try await client.translate("hello", to: .init(code: "es", name: "Spanish"), apiKey: "fake")
                XCTFail("Expected HTTP error")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("private-server-detail"))
                if status == 403 { XCTAssertTrue(error.localizedDescription.contains("GPT-6 Luna")) }
                if status == 429 { XCTAssertTrue(error.localizedDescription.contains("credits")) }
            }
        }
    }

    func testTranslationNetworkCancellationAndTimeout() async {
        for code in [URLError.Code.cancelled, .timedOut, .notConnectedToInternet] {
            let client = OpenAITranslator { _ in throw URLError(code) }
            do {
                _ = try await client.translate("hello", to: .init(code: "es", name: "Spanish"), apiKey: "fake")
                XCTFail("Expected network failure")
            } catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertFalse(error.localizedDescription.isEmpty) }
            }
        }
    }
}
