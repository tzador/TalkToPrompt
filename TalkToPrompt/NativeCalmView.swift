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
    private var mutedInk: Color { ink.opacity(0.62) }
    private var ready: Bool { state.isReady && !state.needsSetup }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            shortcutGuide.padding(.top, 18)

            Text("PREFERENCES")
                .font(.system(size: 12, weight: .semibold)).tracking(1.3)
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
                Text(error).font(.system(size: 13)).foregroundStyle(ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }

            HStack(spacing: 5) {
                Image(systemName: "lock.shield").font(.system(size: 12))
                Text("Audio goes directly to OpenAI")
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                Button(action: actions.quit) {
                    HStack(spacing: 5) {
                        Text("Quit")
                        Image(systemName: "power").font(.system(size: 13, weight: .medium))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color(red: 1, green: 0.45, blue: 0.45) : Color(red: 0.72, green: 0.19, blue: 0.19))
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
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
        .frame(width: 420)
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
            .frame(width: 44, height: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Talk to Prompt").font(.system(size: 20, weight: .semibold))
                Text("Dictate into any app")
                    .font(.system(size: 13)).foregroundStyle(mutedInk)
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
        .frame(height: 44)
    }

    private var statusInk: Color {
        if ready {
            return colorScheme == .dark ? NativeCalmPalette.green : Color(red: 0.08, green: 0.43, blue: 0.20)
        }
        return colorScheme == .dark ? NativeCalmPalette.red : Color(red: 0.70, green: 0.15, blue: 0.18)
    }

    private var readinessBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
            Text(ready ? "Ready" : "Not ready")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(statusInk)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(statusInk.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(statusInk.opacity(0.18)))
    }

    private var shortcutGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Press Shifts to speak")
                .font(.system(size: 19, weight: .semibold))
            Text("Release to transcribe and insert.\nEscape to cancel.")
                .font(.system(size: 14)).lineSpacing(4).foregroundStyle(mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                shiftKey("Left ⇧")
                Text("+").font(.system(size: 17, weight: .medium)).foregroundStyle(mutedInk)
                shiftKey("Right ⇧")
            }
            .padding(.top, 2)
            .accessibilityLabel("Hold both the left and right Shift keys to speak")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
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
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(mutedInk).frame(width: 24, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear API Key").help("Clear the saved API key")
            }
        }
        .padding(.horizontal, 12).frame(height: 66)
    }

    private var loginRow: some View {
        HStack(spacing: 10) {
            rowIcon("arrow.up.right.square")
            rowTitle("Launch at Login", detail: state.loginNeedsApproval || state.loginStatus == "Unavailable"
                     ? state.loginStatus : "Ready when you sign in")
            Spacer(minLength: 4)
            if state.loginNeedsApproval {
                Button(action: actions.loginSettings) {
                    Image(systemName: "gearshape").font(.system(size: 15))
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
        .padding(.horizontal, 12).frame(height: 66)
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
            .labelsHidden().pickerStyle(.menu).frame(width: 136)
            .font(.system(size: 14)).controlSize(.regular)
            .help("Suggest the input language, or choose Auto-detect. Your speech stays in its original language.")
        }
        .padding(.horizontal, 12).frame(height: 66)
    }

    private var rowDivider: some View {
        Rectangle().fill(ink.opacity(0.07)).frame(height: 1).padding(.leading, 46)
    }

    private func rowTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Text(detail).font(.system(size: 12)).foregroundStyle(mutedInk).lineLimit(1)
        }
    }

    private func shiftKey(_ title: String) -> some View {
        Text(title).font(.system(size: 21, weight: .semibold, design: .monospaced))
            .foregroundStyle(ink.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(ink.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ink.opacity(0.13)))
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .regular))
            .foregroundStyle(ink.opacity(0.55))
            .frame(width: 24, height: 24).accessibilityHidden(true)
    }
}

private struct MenuActionStyle: ButtonStyle {
    let ink: Color
    let paper: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(paper)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(ink.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 6))
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
                        .frame(width: 18, height: 18).padding(3)
                }
                .frame(width: 42, height: 24)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.16), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
