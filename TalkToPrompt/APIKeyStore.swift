import Combine
import Foundation
import Security

@MainActor
protocol APIKeyStorage {
    func load() throws -> String?
    func save(_ key: String) throws
    func clear() throws
}

/// A generic-password item in the macOS Keychain. The service identifies this
/// app; Keychain's default access controls restrict access to the creating app.
@MainActor
final class KeychainAPIKeyStore: APIKeyStorage {
    static let account = "OPENAI_API_KEY"
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.talktoprompt.TalkToPrompt") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false
        ]
    }

    func load() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidData
        }
        return key
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "TalkToPrompt OpenAI API Key"
            try check(SecItemAdd(attributes as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
                return "The API key could not be accessed in Keychain. \(reason)"
            case .invalidData:
                return "The saved API key could not be read."
            }
        }
    }
}

@MainActor
final class APIKeyModel: ObservableObject {
    @Published private(set) var maskedKey: String?
    @Published var errorMessage: String?
    private let storage: APIKeyStorage
    private let validate: (String) async throws -> Void

    var isProvided: Bool { maskedKey != nil }
    var status: String { maskedKey.map { "Provided \($0)" } ?? "Not provided" }

    init(storage: APIKeyStorage? = nil, validate: @escaping (String) async throws -> Void = {
        try await OpenAITranscriber().validateAPIKey($0)
    }) {
        self.storage = storage ?? KeychainAPIKeyStore()
        self.validate = validate
    }

    func load() {
        do {
            maskedKey = try storage.load().map(Self.mask)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ input: String) async throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count > 7, !key.contains(where: \.isWhitespace) else {
            throw ValidationError.invalidKey
        }
        try Task.checkCancellation()
        try await validate(key)
        try Task.checkCancellation()
        try storage.save(key)
        maskedKey = Self.mask(key)
        errorMessage = nil
    }

    func clear() {
        do {
            try storage.clear()
            maskedKey = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func mask(_ key: String) -> String {
        // Never reveal an entire short value, including malformed legacy data.
        guard key.count > 7 else { return "••••" }
        return "\(key.prefix(3))...\(key.suffix(4))"
    }

    enum ValidationError: LocalizedError {
        case invalidKey

        var errorDescription: String? {
            "Enter an API key with at least eight characters and no spaces."
        }
    }
}
