import XCTest
@testable import TalkToPrompt

@MainActor
private final class MemoryAPIKeyStorage: APIKeyStorage {
    var value: String?
    var fail = false

    func load() throws -> String? {
        if fail { throw TestError.unavailable }
        return value
    }

    func save(_ key: String) throws {
        if fail { throw TestError.unavailable }
        value = key
    }

    func clear() throws {
        if fail { throw TestError.unavailable }
        value = nil
    }

    enum TestError: Error { case unavailable }
}

final class APIKeyStoreTests: XCTestCase {
    @MainActor
    func testKeychainRoundTripOverwriteAndClear() async throws {
        // Use a unique service so tests never access the user's app credential.
        let service = "com.talktoprompt.tests.\(UUID().uuidString)"
        let store = KeychainAPIKeyStore(service: service)
        defer { try? store.clear() }
        XCTAssertEqual(KeychainAPIKeyStore.account, "OPENAI_API_KEY")
        XCTAssertNil(try store.load())
        try store.save("sk-fake-test-value-one")
        let reopenedStore = KeychainAPIKeyStore(service: service)
        XCTAssertEqual(try reopenedStore.load(), "sk-fake-test-value-one")
        try reopenedStore.save("sk-fake-test-value-two")
        XCTAssertEqual(try store.load(), "sk-fake-test-value-two")
        try store.clear()
        XCTAssertNil(try reopenedStore.load())
        XCTAssertNoThrow(try store.clear())
    }

    @MainActor
    func testKeychainServicesRemainIsolated() async throws {
        let first = KeychainAPIKeyStore(service: "com.talktoprompt.tests.\(UUID().uuidString)")
        let second = KeychainAPIKeyStore(service: "com.talktoprompt.tests.\(UUID().uuidString)")
        defer { try? first.clear(); try? second.clear() }
        try first.save("sk-fake-test-key")
        XCTAssertNil(try second.load())
        try second.clear()
        XCTAssertEqual(try first.load(), "sk-fake-test-key")
    }

    @MainActor
    func testMissingKeyShowsNotProvided() {
        let model = APIKeyModel(storage: MemoryAPIKeyStorage(), validate: { _ in })
        model.load()
        XCTAssertFalse(model.isProvided)
        XCTAssertEqual(model.status, "Not provided")
    }

    @MainActor
    func testSaveTrimsInputAndOnlyDisplaysFirstThreeAndLastFourCharacters() async throws {
        let storage = MemoryAPIKeyStorage()
        let model = APIKeyModel(storage: storage, validate: { _ in })
        try await model.save(" \nsk-fake-test-key-TqUA\n ")
        XCTAssertEqual(storage.value, "sk-fake-test-key-TqUA")
        XCTAssertTrue(model.isProvided)
        XCTAssertEqual(model.status, "Provided sk-...TqUA")
        let reloaded = APIKeyModel(storage: storage, validate: { _ in })
        reloaded.load()
        XCTAssertEqual(reloaded.status, "Provided sk-...TqUA")
    }

    @MainActor
    func testClearDeletesTheStoredValue() async throws {
        let storage = MemoryAPIKeyStorage()
        let model = APIKeyModel(storage: storage, validate: { _ in })
        try await model.save("sk-fake-test-key")
        model.clear()
        XCTAssertNil(storage.value)
        XCTAssertFalse(model.isProvided)
        XCTAssertEqual(model.status, "Not provided")
    }

    @MainActor
    func testFailedSaveDoesNotClaimTheKeyWasStored() async {
        let storage = MemoryAPIKeyStorage()
        storage.fail = true
        let model = APIKeyModel(storage: storage, validate: { _ in })
        await assertSaveFails(model, "sk-fake-test-key")
        XCTAssertFalse(model.isProvided)
        XCTAssertNil(storage.value)
    }

    @MainActor
    func testFailedClearPreservesProvidedStatusAndReportsError() async throws {
        let storage = MemoryAPIKeyStorage()
        let model = APIKeyModel(storage: storage, validate: { _ in })
        try await model.save("sk-fake-test-key")
        let previousStatus = model.status
        storage.fail = true
        model.clear()
        XCTAssertEqual(model.status, previousStatus)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotNil(storage.value)
    }

    @MainActor
    func testInvalidInputDoesNotReachStorage() async {
        let storage = MemoryAPIKeyStorage()
        let model = APIKeyModel(storage: storage, validate: { _ in })
        for input in ["", "   \n", "short", "sk-invalid key"] {
            await assertSaveFails(model, input)
        }
        XCTAssertNil(storage.value)
        XCTAssertFalse(model.isProvided)
    }

    @MainActor
    func testShortExistingValueIsNeverFullyExposed() {
        let storage = MemoryAPIKeyStorage()
        storage.value = "tiny"
        let model = APIKeyModel(storage: storage, validate: { _ in })
        model.load()
        XCTAssertEqual(model.status, "Provided ••••")
    }

    @MainActor
    private func assertSaveFails(_ model: APIKeyModel, _ key: String) async {
        do { try await model.save(key); XCTFail("Expected save failure") }
        catch { }
    }

    @MainActor
    func testValidationFailureNeverStoresOrReplacesAKey() async {
        let storage = MemoryAPIKeyStorage()
        storage.value = "sk-existing-key"
        let model = APIKeyModel(storage: storage, validate: { _ in
            throw OpenAITranscriber.TranscriptionError.rejected(401, false)
        })
        model.load()
        let previous = model.status
        await assertSaveFails(model, "sk-rejected-key")
        XCTAssertEqual(storage.value, "sk-existing-key")
        XCTAssertEqual(model.status, previous)
    }

    @MainActor
    func testNoWriteBeforeValidationCompletesAndCandidateIsTrimmed() async throws {
        let storage = MemoryAPIKeyStorage()
        var reply: CheckedContinuation<Void, Never>?
        var validated: String?
        let model = APIKeyModel(storage: storage, validate: { key in
            validated = key
            await withCheckedContinuation { reply = $0 }
        })
        let task = Task { try await model.save("  sk-fake-validation-test  ") }
        while reply == nil { await Task.yield() }
        XCTAssertNil(storage.value)
        XCTAssertFalse(model.isProvided)
        XCTAssertEqual(validated, "sk-fake-validation-test")
        reply?.resume()
        try await task.value
        XCTAssertEqual(storage.value, validated)
        XCTAssertTrue(model.isProvided)
    }

    @MainActor
    func testCancellationPreventsStorageEvenIfValidationReturnsSuccessLate() async {
        let storage = MemoryAPIKeyStorage()
        var reply: CheckedContinuation<Void, Never>?
        let model = APIKeyModel(storage: storage, validate: { _ in
            await withCheckedContinuation { reply = $0 }
        })
        let task = Task { try await model.save("sk-fake-cancelled-key") }
        while reply == nil { await Task.yield() }
        task.cancel()
        reply?.resume()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(storage.value)
        XCTAssertFalse(model.isProvided)
    }

    @MainActor
    func testLoadFailureIsReported() {
        let storage = MemoryAPIKeyStorage()
        storage.fail = true
        let model = APIKeyModel(storage: storage, validate: { _ in })
        model.load()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isProvided)
    }
}
