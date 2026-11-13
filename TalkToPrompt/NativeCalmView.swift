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

    private var ink: Color { colorScheme == .dark ? .white : .black }
    private var paper: Color { colorScheme == .dark ? Color(white: 0.075) : .white }
    private var mutedInk: Color { ink.opacity(0.48) }
    private var ready: Bool { state.isReady && !state.needsSetup }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            shortcutGuide.padding(.top, 18)

            Text("PREFERENCES")
                .font(.system(size: 10, weight: .semibold)).tracking(1.3)
                .foregroundStyle(mutedInk)
                .padding(.top, 20).padding(.bottom, 9)

            VStack(spacing: 0) {
                apiKeyRow
                rowDivider
                loginRow
                rowDivider
                languageRow
            }
            .background(ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ink.opacity(0.08)))

            if let error = state.loginError {
                Text(error).font(.system(size: 11)).foregroundStyle(ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }

            HStack(spacing: 5) {
                Image(systemName: "lock.shield").font(.system(size: 10))
                Text("Audio goes directly to OpenAI")
                    .font(.system(size: 10))
                Spacer(minLength: 8)
                Button(action: actions.quit) {
                    HStack(spacing: 5) {
                        Text("Quit")
                        Image(systemName: "power").font(.system(size: 10, weight: .medium))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colorScheme == .dark ? Color(red: 1, green: 0.45, blue: 0.45) : Color(red: 0.72, green: 0.19, blue: 0.19))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color.red.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityLabel("Quit TalkToPrompt")
            }
            .foregroundStyle(mutedInk)
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(paper)
        .foregroundStyle(ink)
        .tint(ink)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("TalkToPrompt")
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(ink)
                if let image = MenuBarIcon.statusImage() {
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(paper).padding(8)
                } else {
                    Image(systemName: "waveform").font(.system(size: 21, weight: .medium))
                        .foregroundStyle(paper)
                }
            }
            .frame(width: 40, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("TalkToPrompt").font(.system(size: 17, weight: .semibold))
                Text("Voice, wherever you write.")
                    .font(.system(size: 11)).foregroundStyle(mutedInk)
            }
            Spacer(minLength: 4)
            if ready {
                readinessBadge
            } else {
                Button(action: actions.setup) { readinessBadge }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not ready. Finish setup")
                    .help("Finish setup to start dictating")
            }
        }
        .frame(height: 40)
    }

    private var readinessBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 10, weight: .medium))
            Text(ready ? "Ready" : "Set up")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(ink.opacity(ready ? 0.85 : 0.6))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(ink.opacity(0.055), in: Capsule())
    }

    private var shortcutGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hold to speak").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 6)
                shiftKey("Left ⇧")
                Text("+").font(.system(size: 10)).foregroundStyle(mutedInk)
                shiftKey("Right ⇧")
            }
            HStack(spacing: 0) {
                Text("Release to insert")
                Text("  ·  ")
                Text("Esc").font(.system(size: 10, weight: .medium, design: .monospaced))
                Text(" to cancel")
            }
            .font(.system(size: 11)).foregroundStyle(mutedInk)
        }
        .padding(12)
        .background(ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var apiKeyRow: some View {
        HStack(spacing: 10) {
            rowIcon("key.horizontal")
            rowTitle("OpenAI API key", detail: state.apiKeyUnavailable ? "Unable to read key" : state.apiKeyStatus)
            Spacer(minLength: 4)
            Button(state.hasAPIKey ? "Change" : "Add key", action: actions.apiKey)
                .accessibilityLabel(state.hasAPIKey ? "Change API Key" : "Enter API Key")
                .buttonStyle(MenuActionStyle(ink: ink, paper: paper))
            if state.hasAPIKey {
                Button(action: actions.clearAPIKey) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(mutedInk).frame(width: 18, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear API Key").help("Clear the saved API key")
            }
        }
        .padding(.horizontal, 12).frame(height: 58)
    }

    private var loginRow: some View {
        HStack(spacing: 10) {
            rowIcon("arrow.up.right.square")
            rowTitle("Launch at Login", detail: state.loginNeedsApproval || state.loginStatus == "Unavailable"
                     ? state.loginStatus : "Ready when you sign in")
            Spacer(minLength: 4)
            if state.loginNeedsApproval {
                Button(action: actions.loginSettings) {
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(mutedInk)
                .accessibilityLabel("Open System Settings → Login Items")
                .help("Approve TalkToPrompt in Login Items")
            }
            Toggle("Launch at Login", isOn: Binding(
                get: { state.loginRequested }, set: { actions.setLogin($0) }
            ))
            .toggleStyle(MonochromeSwitchStyle(ink: ink, paper: paper))
            .help("Start TalkToPrompt when you sign in to your Mac, including after a restart")
        }
        .padding(.horizontal, 12).frame(height: 58)
    }

    private var languageRow: some View {
        HStack(spacing: 10) {
            rowIcon("globe")
            rowTitle("Language hint", detail: "Language you’ll speak")
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
            .labelsHidden().pickerStyle(.menu).frame(width: 124)
            .controlSize(.small)
            .help("Suggest the input language, or choose Auto-detect. Your speech stays in its original language.")
        }
        .padding(.horizontal, 12).frame(height: 58)
    }

    private var rowDivider: some View {
        Rectangle().fill(ink.opacity(0.07)).frame(height: 1).padding(.leading, 46)
    }

    private func rowTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(detail).font(.system(size: 10)).foregroundStyle(mutedInk).lineLimit(1)
        }
    }

    private func shiftKey(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(paper, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.10)))
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .regular))
            .foregroundStyle(ink.opacity(0.55))
            .frame(width: 24, height: 24).accessibilityHidden(true)
    }
}

private struct MenuActionStyle: ButtonStyle {
    let ink: Color
    let paper: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .medium))
            .foregroundStyle(ink.opacity(configuration.isPressed ? 0.6 : 0.85))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(paper, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.opacity(0.14)))
            .contentShape(Rectangle())
    }
}

private struct MonochromeSwitchStyle: ToggleStyle {
    let ink: Color
    let paper: Color

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? ink : ink.opacity(0.13))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? paper : ink.opacity(0.45))
                        .frame(width: 14, height: 14).padding(3)
                }
                .frame(width: 34, height: 20)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.16), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
