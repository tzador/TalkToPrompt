import SwiftUI

struct APIKeyEntrySheet: View {
    let onSave: (String) async throws -> Void
    let onCancel: () -> Void
    @State private var key = ""
    @State private var errorMessage: String?
    @State private var isValidating = false
    @State private var validationTask: Task<Void, Never>?
    @FocusState private var isKeyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OpenAI API Key")
                .font(.title2.bold())
            if isValidating {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Validating API key...")
                        .font(.headline)
                }
                Text("Checking transcription access with OpenAI. Your key will only be saved if the check succeeds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                SecureField("Enter your API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                    .focused($isKeyFocused)
                    .onSubmit(save)
                    .accessibilityLabel("OpenAI API Key")
                Link("Get an OpenAI API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.callout)
                Text("Validated before being stored securely in this app’s macOS Keychain item. The check sends one second of generated silence to OpenAI; a small API charge may apply.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(NativeCalmPalette.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    validationTask?.cancel()
                    key = ""
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                if !isValidating {
                    Button("OK", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(28)
        .frame(width: 440)
        .onAppear { isKeyFocused = true }
        .onDisappear { validationTask?.cancel(); key = "" }
    }

    private func save() {
        guard !isValidating else { return }
        let candidate = key
        errorMessage = nil
        isValidating = true
        validationTask = Task { @MainActor in
            defer { isValidating = false }
            do {
                try await onSave(candidate)
                key = ""
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "The key was not saved. " + error.localizedDescription
                isKeyFocused = true
            }
        }
    }
}
