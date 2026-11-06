import AppKit
import SwiftUI

/// Accent colors sampled from the supplied window-control reference.
enum NativeCalmPalette {
    static let green = Color(.sRGB, red: 53 / 255, green: 199 / 255, blue: 89 / 255)
    static let yellow = Color(.sRGB, red: 250 / 255, green: 200 / 255, blue: 0)
    static let red = Color(.sRGB, red: 1, green: 92 / 255, blue: 96 / 255)
}

struct NativeCalmState: Equatable {
    var isReady: Bool
    var apiKeyStatus: String
    var hasAPIKey: Bool
    var apiKeyUnavailable = false
    var needsSetup = false
    var loginRequested = false
    var loginNeedsApproval = false
    var loginStatus = "Disabled"
    var loginError: String?
    var transcriptionLanguage = ""
}

@MainActor
struct NativeCalmView: View {
    struct Actions {
        var apiKey: () -> Void
        var clearAPIKey: () -> Void = {}
        var setup: () -> Void = {}
        var setLogin: (Bool) -> Void = { _ in }
        var setTranscriptionLanguage: (String) -> Void = { _ in }
        var loginSettings: () -> Void = {}
        var quit: @MainActor () -> Void = { NSApp.terminate(nil) }
    }

    let state: NativeCalmState
    let actions: Actions
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                if let image = MenuBarIcon.statusImage() {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: 24, height: 24).accessibilityHidden(true)
                }
                Text("TalkToPrompt").font(.system(size: 19, weight: .semibold))
                Spacer(minLength: 4)
                if state.isReady && !state.needsSetup {
                    readinessBadge(ready: true)
                } else {
                    Button(action: actions.setup) { readinessBadge(ready: false) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Not ready. Finish setup")
                        .help("Finish setup to start dictating")
                }
            }
            HStack(spacing: 10) {
                rowIcon("key")
                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenAI API key").font(.callout.weight(.medium))
                    Text(state.apiKeyUnavailable ? "Unable to read key" : state.apiKeyStatus)
                        .font(.caption).foregroundStyle(state.apiKeyUnavailable || !state.hasAPIKey ? errorInk : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(state.hasAPIKey ? "Change" : "Enter", action: actions.apiKey)
                    .accessibilityLabel(state.hasAPIKey ? "Change API Key" : "Enter API Key")
                if state.hasAPIKey {
                    Button(action: actions.clearAPIKey) { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear API Key").help("Clear the saved API key")
                }
            }
            .frame(height: 44)
            HStack(spacing: 10) {
                rowIcon("power")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Launch at Login").font(.callout.weight(.medium))
                    if state.loginNeedsApproval || state.loginStatus == "Unavailable" {
                        Text(state.loginStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if state.loginNeedsApproval {
                    Button(action: actions.loginSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Open System Settings → Login Items")
                        .help("Approve TalkToPrompt in Login Items")
                }
                Toggle("Launch at Login", isOn: Binding(
                    get: { state.loginRequested }, set: { actions.setLogin($0) }
                ))
                .toggleStyle(.switch).labelsHidden().tint(NativeCalmPalette.green)
                .accessibilityLabel("Launch at Login")
                .help("Start TalkToPrompt when you sign in to your Mac, including after a restart")
            }
            .frame(height: 44)
            if let error = state.loginError {
                Text(error).font(.caption).foregroundStyle(errorInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                rowIcon("globe")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Language hint").font(.callout.weight(.medium))
                    Text("Language you’ll speak").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Picker("Language hint", selection: Binding(
                    get: { state.transcriptionLanguage }, set: actions.setTranscriptionLanguage
                )) {
                    Text("Auto-detect").tag("")
                    Divider()
                    ForEach(TranscriptionLanguage.all) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 156)
                .help("Suggest the input language, or choose Auto-detect. Your speech stays in its original language.")
            }
            .frame(height: 44)
            HStack(spacing: 10) {
                rowIcon("lock")
                Text("Audio goes directly to OpenAI.").font(.callout)
                Spacer(minLength: 0)
                Button("Quit", action: actions.quit)
                    .foregroundStyle(errorInk)
                    .keyboardShortcut("q", modifiers: .command)
                    .accessibilityLabel("Quit TalkToPrompt")
            }
            .foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Hold both Shift keys to dictate")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 7) {
                    shiftKey("Left ⇧")
                    Text("+").font(.headline).foregroundStyle(.secondary)
                    shiftKey("Right ⇧")
                    Spacer(minLength: 0)
                }
                Text("Speak, then release to insert your words.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.bordered)
        .padding(16)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("TalkToPrompt")
    }

    private func readinessBadge(ready: Bool) -> some View {
        let ink = ready
            ? (colorScheme == .dark ? NativeCalmPalette.green : Color(.sRGB, red: 0.08, green: 0.44, blue: 0.17))
            : errorInk
        return HStack(spacing: 6) {
            Circle().fill(ink).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(ready ? "Ready" : "Not ready").font(.system(size: 14, weight: .bold))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(ink.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(ink.opacity(0.25)))
    }

    private func shiftKey(_ title: String) -> some View {
        Text(title).font(.system(size: 17, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.14)))
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17))
            .frame(width: 24, height: 24).accessibilityHidden(true)
    }

    private var errorInk: Color {
        colorScheme == .dark ? NativeCalmPalette.red : Color(.sRGB, red: 0.70, green: 0.15, blue: 0.18)
    }
}
