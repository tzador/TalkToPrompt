import SwiftUI

struct APIKeyEntrySheet: View {
    let onSave: (String) throws -> Void
    let onCancel: () -> Void
    @State private var key = ""
    @State private var errorMessage: String?
    @FocusState private var isKeyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OpenAI API Key")
                .font(.title2.bold())
            SecureField("Enter your API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .privacySensitive()
                .focused($isKeyFocused)
                .onSubmit(save)
                .accessibilityLabel("OpenAI API Key")
            Text("Stored securely in this app’s macOS Keychain item.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    key = ""
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("OK", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 440)
        .onAppear { isKeyFocused = true }
        .onDisappear { key = "" }
    }

    private func save() {
        do {
            try onSave(key)
            key = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
