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
        var clearAPIKey: () -> Void = {}
        var quit: @MainActor () -> Void = { NSApp.terminate(nil) }
    }

    let state: NativeCalmState
    let actions: Actions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var schemeContrast

    private let iconWidth: CGFloat = 24
    private let rowSpacing: CGFloat = 10
    private var isDark: Bool { colorScheme == .dark }
    private var outline: Color { Color.primary.opacity(schemeContrast == .increased ? 0.35 : 0.12) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            shortcutGuide
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                permissionRow("Input Monitoring", icon: "keyboard", requirement: state.inputMonitoring, action: actions.inputMonitoring)
                permissionRow("Accessibility", icon: "accessibility", requirement: state.accessibility, action: actions.accessibility)
                permissionRow("Microphone", icon: "mic", requirement: state.microphone, action: actions.microphone)
            }
            Divider()
            VStack(spacing: 6) {
                HStack(spacing: rowSpacing) {
                    rowIcon("key")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("OpenAI API key").font(.callout.weight(.medium))
                        Text(state.apiKeyUnavailable ? "Unable to read key" : state.apiKeyStatus)
                            .font(.caption)
                            .foregroundStyle(state.apiKeyUnavailable || !state.hasAPIKey ? errorInk : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button(state.hasAPIKey ? "Change" : "Enter", action: actions.apiKey)
                        .accessibilityLabel(state.hasAPIKey ? "Change API Key" : "Enter API Key")
                    if state.hasAPIKey {
                        Button(action: actions.clearAPIKey) {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear API Key")
                        .help("Clear the saved API key")
                    }
                }
                .frame(height: 44)
                .accessibilityIdentifier("setting-API Key")
                HStack(spacing: rowSpacing) {
                    rowIcon("power")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login").font(.callout.weight(.medium))
                        if state.loginNeedsApproval || state.loginUnavailable {
                            Text(state.loginStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 6)
                    if state.loginNeedsApproval {
                        settingsButton("Login Items", action: actions.loginSettings)
                    }
                    Toggle("Launch at Login", isOn: Binding(
                        get: { state.loginRequested }, set: { actions.setLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(NativeCalmPalette.green)
                    .accessibilityLabel("Launch at Login")
                }
                .frame(height: 40)
                .accessibilityIdentifier("setting-Launch at Login")
            }
            // The same icon slot and spacing align this baseline with every setting label.
            HStack(spacing: rowSpacing) {
                rowIcon("lock")
                Text("Audio goes directly to OpenAI.")
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .frame(height: 28)
            Divider()
            HStack {
                Spacer()
                Button(action: actions.quit) {
                    Label("Quit TalkToPrompt", systemImage: "power")
                }
                .foregroundStyle(errorInk)
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityIdentifier("quit-TalkToPrompt")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(16)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("TalkToPrompt setup and usage")
    }

    private var header: some View {
        HStack(spacing: rowSpacing) {
            if let image = MenuBarIcon.image(color: .labelColor) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: iconWidth, height: 24)
                    .accessibilityHidden(true)
            }
            Text("TalkToPrompt").font(.system(size: 20, weight: .semibold))
            Spacer(minLength: 8)
            Circle().fill(state.isReady ? NativeCalmPalette.green : NativeCalmPalette.red)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(state.isReady ? "Ready" : (state.isChecking ? "Checking…" : "Setup required"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 30)
    }

    private var shortcutGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(["Left Shift", "Right Shift"], id: \.self) { name in
                    Image(systemName: "shift")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 30, height: 25)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(outline, lineWidth: 1) }
                        .accessibilityLabel(name)
                }
                Text("Hold both Shift keys")
                    .font(.callout.weight(.semibold))
                    .padding(.leading, 4)
            }
            Text("Speak, then release to insert text.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(isDark ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .regular))
            .frame(width: iconWidth, height: 24, alignment: .center)
            .accessibilityHidden(true)
    }

    private func permissionRow(_ title: String, icon: String, requirement: NativeCalmState.Requirement, action: @escaping () -> Void) -> some View {
        HStack(spacing: rowSpacing) {
            rowIcon(icon)
            Text(title).font(.callout.weight(.medium))
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Image(systemName: requirement == .granted ? "checkmark" : "exclamationmark.circle")
                    .foregroundStyle(requirement == .granted ? NativeCalmPalette.green : (requirement == .missing ? NativeCalmPalette.red : NativeCalmPalette.yellow))
                    .accessibilityHidden(true)
                Text(requirement == .granted ? "Granted" : (requirement == .missing ? "Not granted" : (requirement == .checking ? "Checking…" : "Restart")))
                    .foregroundStyle(requirement == .granted ? successInk : (requirement == .missing ? errorInk : .secondary))
            }
            .font(.caption)
            .accessibilityLabel(requirement.title)
            settingsButton(title, action: action)
        }
        .frame(height: 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setting-" + title)
    }

    private func settingsButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .frame(width: 16, height: 16)
        }
        .help("Open System Settings → " + title)
        .accessibilityLabel("Open System Settings → " + title)
    }

    private var successInk: Color {
        isDark ? NativeCalmPalette.green : Color(.sRGB, red: 0.10, green: 0.40, blue: 0.18)
    }

    private var errorInk: Color {
        isDark ? NativeCalmPalette.red : Color(.sRGB, red: 0.70, green: 0.15, blue: 0.18)
    }
}
