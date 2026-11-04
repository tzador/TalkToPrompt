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
    func testKeychainRoundTripOverwriteAndClear() throws {
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
    func testKeychainServicesRemainIsolated() throws {
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
        let model = APIKeyModel(storage: MemoryAPIKeyStorage())
        model.load()
        XCTAssertFalse(model.isProvided)
        XCTAssertEqual(model.status, "Not provided")
    }

    @MainActor
    func testSaveTrimsInputAndOnlyDisplaysFirstThreeAndLastFourCharacters() throws {
        let storage = MemoryAPIKeyStorage()
        let model = APIKeyModel(storage: storage)
        try model.save(" \nsk-fake-test-key-TqUA\n ")
        XCTAssertEqual(storage.value, "sk-fake-test-key-TqUA")
        XCTAssertTrue(model.isProvided)
        XCTAssertEqual(model.status, "Provided sk-...TqUA")
        let reloaded = APIKeyModel(storage: storage)
        reloaded.load()
        XCTAssertEqual(reloaded.status, "Provided sk-...TqUA")
    }

    @MainActor
    func testClearDeletesTheStoredValue() throws {
        let storage = MemoryAPIKeyStorage()
        let model = APIKeyModel(storage: storage)
        try model.save("sk-fake-test-key")
        model.clear()
        XCTAssertNil(storage.value)
        XCTAssertFalse(model.isProvided)
        XCTAssertEqual(model.status, "Not provided")
    }

    @MainActor
    func testFailedSaveDoesNotClaimTheKeyWasStored() {
        let storage = MemoryAPIKeyStorage()
        storage.fail = true
        let model = APIKeyModel(storage: storage)
        XCTAssertThrowsError(try model.save("sk-fake-test-key"))
        XCTAssertFalse(model.isProvided)
        XCTAssertNil(storage.value)
    }

    @MainActor
    func testFailedClearPreservesProvidedStatusAndReportsError() throws {
        let storage = MemoryAPIKeyStorage()
        let model = APIKeyModel(storage: storage)
        try model.save("sk-fake-test-key")
        let previousStatus = model.status
        storage.fail = true
        model.clear()
        XCTAssertEqual(model.status, previousStatus)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotNil(storage.value)
    }

    @MainActor
    func testInvalidInputDoesNotReachStorage() {
        let storage = MemoryAPIKeyStorage()
        let model = APIKeyModel(storage: storage)
        for input in ["", "   \n", "short", "sk-invalid key"] {
            XCTAssertThrowsError(try model.save(input))
        }
        XCTAssertNil(storage.value)
        XCTAssertFalse(model.isProvided)
    }

    @MainActor
    func testShortExistingValueIsNeverFullyExposed() {
        let storage = MemoryAPIKeyStorage()
        storage.value = "tiny"
        let model = APIKeyModel(storage: storage)
        model.load()
        XCTAssertEqual(model.status, "Provided ••••")
    }

    @MainActor
    func testLoadFailureIsReported() {
        let storage = MemoryAPIKeyStorage()
        storage.fail = true
        let model = APIKeyModel(storage: storage)
        model.load()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isProvided)
    }
}
