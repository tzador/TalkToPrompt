import AppKit
import SwiftUI

/// Accent colors sampled from the supplied window-control reference.
enum NativeCalmPalette {
    static let green = Color(.sRGB, red: 53 / 255, green: 199 / 255, blue: 89 / 255)
    static let yellow = Color(.sRGB, red: 250 / 255, green: 200 / 255, blue: 0)
    static let red = Color(.sRGB, red: 1, green: 92 / 255, blue: 96 / 255)
}

struct NativeCalmState: Equatable {
    enum Requirement: Equatable {
        case checking, granted, missing, restartRequired

        var title: String {
            switch self {
            case .checking: return "Checking permission…"
            case .granted: return "Permission granted"
            case .missing: return "Permission not granted"
            case .restartRequired: return "Restart required"
            }
        }
    }

    var inputMonitoring: Requirement
    var accessibility: Requirement
    var microphone: Requirement
    var apiKeyStatus: String
    var hasAPIKey: Bool
    var apiKeyUnavailable = false
    var loginStatus: String
    var loginRequested: Bool
    var loginNeedsApproval: Bool
    var loginUnavailable = false

    var isReady: Bool {
        inputMonitoring == .granted && accessibility == .granted
            && microphone == .granted && hasAPIKey && !apiKeyUnavailable
    }

    var isChecking: Bool { inputMonitoring == .checking || accessibility == .checking }
    var needsRestart: Bool { inputMonitoring == .restartRequired }
}

@MainActor
struct NativeCalmView: View {
    struct Actions {
        var inputMonitoring: () -> Void
        var accessibility: () -> Void
        var microphone: () -> Void
        var apiKey: () -> Void
        var setLogin: (Bool) -> Void
        var loginSettings: () -> Void
    }

    let state: NativeCalmState
    let actions: Actions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var schemeContrast

    private let rowHeight: CGFloat = 56
    private let windowPadding: CGFloat = 24
    private var isDark: Bool { colorScheme == .dark }
    private var surface: Color {
        isDark ? Color(.sRGB, red: 41 / 255, green: 41 / 255, blue: 44 / 255)
            : Color(nsColor: .controlBackgroundColor)
    }
    private var outline: Color { Color.primary.opacity(schemeContrast == .increased ? 0.35 : (isDark ? 0.16 : 0.12)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            section("Permissions") {
                group {
                    permissionRow("Input Monitoring", icon: "keyboard", requirement: state.inputMonitoring, action: actions.inputMonitoring)
                    rowDivider
                    permissionRow("Accessibility", icon: "accessibility", requirement: state.accessibility, action: actions.accessibility)
                    rowDivider
                    permissionRow("Microphone", icon: "mic", requirement: state.microphone, action: actions.microphone)
                }
            }
            section("OpenAI") {
                group {
                    settingsRow("API Key", icon: "key") {
                        status(state.apiKeyUnavailable ? "Unable to read key" : state.apiKeyStatus,
                               tone: state.hasAPIKey && !state.apiKeyUnavailable ? .success : .error,
                               symbol: state.hasAPIKey && !state.apiKeyUnavailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    } controls: {
                        neutralButton(state.hasAPIKey ? "Clear" : "Enter", action: actions.apiKey)
                            .accessibilityLabel(state.hasAPIKey ? "Clear API Key" : "Enter API Key")
                    }
                }
            }
            section("Preferences") {
                group {
                    settingsRow("Launch at Login", icon: "power") {
                        status(state.loginStatus,
                               tone: state.loginUnavailable ? .error : (state.loginNeedsApproval ? .warning : (state.loginRequested ? .success : .neutral)),
                               symbol: state.loginNeedsApproval ? "exclamationmark.circle.fill" : nil)
                    } controls: {
                        HStack(spacing: 12) {
                            if state.loginNeedsApproval {
                                neutralButton("Open System Settings", action: actions.loginSettings)
                                    .accessibilityLabel("Open System Settings → Login Items")
                            }
                            Toggle("Launch at Login", isOn: Binding(
                                get: { state.loginRequested }, set: { actions.setLogin($0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(NativeCalmPalette.green)
                            .accessibilityLabel("Launch at Login")
                            .help("Open TalkToPrompt automatically when you sign in to your Mac")
                        }
                    }
                }
            }
            usageGuide
        }
        .padding(.horizontal, windowPadding)
        .padding(.vertical, windowPadding)
        .frame(width: 720)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("TalkToPrompt setup and usage")
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let url = Bundle.main.url(forResource: "TalkToPromptIcon", withExtension: "icns"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("TalkToPrompt").font(.system(size: 25, weight: .bold))
                Text("Speak naturally. Write anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            let tone: Tone = state.isReady ? .success : (state.isChecking || state.needsRestart ? .warning : .error)
            Label(state.isReady ? "Ready to use" : (state.isChecking ? "Checking setup…" : (state.needsRestart ? "Restart required" : "Setup required")),
                  systemImage: state.isReady ? "checkmark.circle.fill" : (state.isChecking ? "circle.dotted" : "exclamationmark.circle.fill"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(ink(tone))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(accent(tone).opacity(isDark ? 0.17 : 0.12), in: Capsule())
                .fixedSize()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.leading, 8)
            content()
        }
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(outline, lineWidth: 1) }
    }

    private var rowDivider: some View {
        Rectangle().fill(outline).frame(height: 1).padding(.horizontal, 16)
    }

    private func settingsRow<Status: View, Controls: View>(
        _ title: String, icon: String,
        @ViewBuilder status: () -> Status, @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
            }
            .frame(width: 166, alignment: .leading)
            status().frame(maxWidth: .infinity, alignment: .leading)
            controls().frame(minWidth: 146, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setting-\(title)")
    }

    private func permissionRow(_ title: String, icon: String, requirement: NativeCalmState.Requirement, action: @escaping () -> Void) -> some View {
        settingsRow(title, icon: icon) {
            status(requirement.title,
                   tone: requirement == .granted ? .success : (requirement == .missing ? .error : .warning),
                   symbol: requirement == .granted ? "checkmark.circle.fill" : (requirement == .checking ? "circle.dotted" : "exclamationmark.circle.fill"))
        } controls: {
            neutralButton("Open System Settings", action: action)
                .accessibilityLabel("Open System Settings → \(title)")
        }
    }

    private func neutralButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .font(.callout)
    }

    private enum Tone { case success, warning, error, neutral }

    private func accent(_ tone: Tone) -> Color {
        switch tone {
        case .success: return NativeCalmPalette.green
        case .warning: return NativeCalmPalette.yellow
        case .error: return NativeCalmPalette.red
        case .neutral: return .secondary
        }
    }

    /// Keep the sampled accents on indicators, with darker same-hue text in light mode.
    private func ink(_ tone: Tone) -> Color {
        if isDark { return accent(tone) }
        switch tone {
        case .success: return Color(.sRGB, red: 0.10, green: 0.40, blue: 0.18)
        case .warning: return Color(.sRGB, red: 0.45, green: 0.34, blue: 0)
        case .error: return Color(.sRGB, red: 0.70, green: 0.15, blue: 0.18)
        case .neutral: return .secondary
        }
    }

    private func status(_ title: String, tone: Tone, symbol: String?) -> some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(accent(tone)).accessibilityHidden(true)
            }
            Text(title).foregroundStyle(ink(tone)).lineLimit(1)
        }
        .font(.callout)
        .help(title)
        .accessibilityLabel(title)
    }

    private var usageGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hold both Shift keys to speak").font(.system(size: 18, weight: .semibold))
            HStack(spacing: 14) {
                keycap("Left Shift")
                Text("+").font(.title3).foregroundStyle(.secondary)
                keycap("Right Shift")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 8) {
                step("1", text: Text("Click a text field in any app."))
                step("2", text: Text("Hold both Shift keys").bold() + Text(" and speak."))
                step("3", text: Text("Release either Shift").bold() + Text(" to transcribe and paste."))
            }
            Rectangle().fill(outline).frame(height: 1)
            Label("Audio is sent to OpenAI using your API key.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(outline, lineWidth: 1) }
    }

    private func keycap(_ title: String) -> some View {
        Label(title, systemImage: "shift")
            .font(.callout.weight(.medium))
            .frame(width: 132, height: 36)
            .background(Color(nsColor: .controlColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(outline, lineWidth: 1) }
            .shadow(color: .black.opacity(isDark ? 0.18 : 0.08), radius: 1, y: 2)
            .accessibilityElement(children: .combine)
    }

    private func step(_ number: String, text: Text) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            text.font(.callout)
        }
    }
}
