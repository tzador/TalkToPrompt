import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = ShiftMonitor()
    @StateObject private var apiKey = APIKeyModel()
    @StateObject private var launchAtLogin = LaunchAtLoginModel()
    @State private var showAPIKeyEntry = false
    @State private var dockIcon = DockIconController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            statusPanel
            usageGuide
            Spacer(minLength: 0)
        }
        .frame(width: 720, height: 720)
        .onAppear {
            monitor.start()
            apiKey.load()
            launchAtLogin.refresh()
        }
        .onChange(of: dockIconState, initial: true) { _, state in
            dockIcon.update(state)
        }
        .onDisappear {
            monitor.stop()
            dockIcon.restore()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                launchAtLogin.refresh()
                monitor.applicationActivated(bundleIdentifier: Bundle.main.bundleIdentifier)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            dockIcon.restore()
            monitor.stop()
        }
        .sheet(isPresented: $monitor.showPermissionExplanation) {
            VStack(spacing: 16) {
                Image(systemName: "keyboard")
                    .font(.largeTitle)
                Text("Enable Keyboard Permissions")
                    .font(.title2.bold())
                Text("Input Monitoring detects both Shift keys while other apps are active. Accessibility allows sending the Paste shortcut to the focused app.")
                VStack(spacing: 12) {
                    if monitor.hasInputMonitoringPermission {
                        Label("Input Monitoring: Permission granted", systemImage: "checkmark.circle")
                    } else {
                        Button("Open System Settings") { monitor.openInputMonitoringSettings() }
                            .help("Open Input Monitoring settings")
                    }
                    if monitor.hasEventPostingPermission {
                        Label("Accessibility: Permission granted", systemImage: "checkmark.circle")
                    } else {
                        Button("Open System Settings") { monitor.openAccessibilitySettings() }
                            .help("Open Accessibility settings")
                    }
                }
                Text("The app watches Shift keys. It does not record what you type.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Not Now", role: .cancel) {
                        monitor.showPermissionExplanation = false
                    }
                }
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .frame(width: 440)
        }
        .sheet(isPresented: $showAPIKeyEntry) {
            APIKeyEntrySheet(
                onSave: { key in
                    try await apiKey.save(key)
                    showAPIKeyEntry = false
                },
                onCancel: { showAPIKeyEntry = false }
            )
        }
        .alert(alertTitle, isPresented: Binding(
            get: {
                monitor.showRestartConfirmation || monitor.playbackError != nil
                    || monitor.restartError != nil || apiKey.errorMessage != nil
                    || monitor.microphone.errorMessage != nil || monitor.transcriptionError != nil
                    || launchAtLogin.errorMessage != nil
            },
            set: { if !$0 { dismissAlert() } }
        )) {
            if monitor.showRestartConfirmation {
                Button("Restart") { Task { await monitor.restart() } }
                Button("Not Now", role: .cancel) { monitor.showRestartConfirmation = false }
            } else {
                Button("OK", role: .cancel) { dismissAlert() }
            }
        } message: {
            if monitor.showRestartConfirmation {
                Text("If you enabled Accessibility in System Settings, restart TalkToPrompt to make sure the change takes effect.")
            } else {
                Text(monitor.restartError ?? launchAtLogin.errorMessage ?? apiKey.errorMessage ?? monitor.microphone.errorMessage ?? monitor.transcriptionError ?? monitor.playbackError ?? "The action could not be completed.")
            }
        }
    }

    private var dockIconState: DockIconController.State {
        .permissions(
            inputMonitoring: monitor.hasInputMonitoringPermission,
            accessibility: monitor.hasEventPostingPermission,
            microphone: monitor.microphone.authorization == .authorized,
            apiKey: apiKey.isProvided
        )
    }

    private var alertTitle: String {
        if monitor.showRestartConfirmation { return "Restart TalkToPrompt?" }
        if monitor.restartError != nil { return "Unable to Restart" }
        if launchAtLogin.errorMessage != nil { return "Unable to Change Launch at Login" }
        if apiKey.errorMessage != nil { return "Unable to Access API Key" }
        if monitor.microphone.errorMessage != nil { return "Unable to Record Audio" }
        if monitor.transcriptionError != nil { return "Unable to Transcribe or Paste" }
        return "Unable to Play Audio"
    }

    private func dismissAlert() {
        monitor.showRestartConfirmation = false
        monitor.playbackError = nil
        monitor.transcriptionError = nil
        monitor.restartError = nil
        apiKey.errorMessage = nil
        launchAtLogin.errorMessage = nil
        monitor.microphone.errorMessage = nil
    }

    private var statusPanel: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                permissionStatus(
                    title: "Input Monitoring",
                    enabled: monitor.hasInputMonitoringPermission,
                    openSettings: { monitor.openInputMonitoringSettings() }
                )
                permissionStatus(
                    title: "Accessibility",
                    enabled: monitor.hasEventPostingPermission,
                    openSettings: { monitor.openAccessibilitySettings() }
                )
                statusBubble(
                    title: "Microphone",
                    status: monitor.microphone.authorization == .authorized ? "Permission granted" : "Permission not granted",
                    color: monitor.microphone.authorization == .authorized ? .green : .orange,
                    icon: "mic.fill",
                    buttonTitle: "Open System Settings"
                ) {
                    Task { await monitor.microphone.openSettings() }
                }
                statusBubble(
                    title: "OpenAI API Key",
                    status: apiKey.status,
                    color: apiKey.isProvided ? .green : .orange,
                    icon: "key.fill",
                    buttonTitle: apiKey.isProvided ? "Clear" : "Enter"
                ) {
                    if apiKey.isProvided {
                        apiKey.clear()
                    } else {
                        showAPIKeyEntry = true
                    }
                }
                bubble(
                    title: "Launch at Login", status: launchAtLogin.statusText,
                    color: launchAtLogin.isEnabled ? .green : .orange,
                    icon: "power"
                ) {
                    if launchAtLogin.needsApproval {
                        Button("Open System Settings") { launchAtLogin.openLoginItemsSettings() }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(.black.opacity(0.85))
                    }
                    Toggle("Launch at Login", isOn: Binding(
                        get: { launchAtLogin.isRequested },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Launch at Login")
                    .help("Open TalkToPrompt automatically when you sign in to your Mac")
                }
            }
            .padding(16)
            .background(.bar)
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App status")
    }

    private var usageGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Turn your voice into text")
                .font(.title2.bold())
            Text("Capture a thought, draft a message, or write a prompt without breaking your flow. TalkToPrompt turns your speech into text in the app you’re using.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                usageStep("1", title: "Choose where to write.", detail: "Click a text field in any app.")
                usageStep("2", title: "Hold both Shift keys and speak.", detail: "The overlay shows Listening… once recording starts.")
                usageStep("3", title: "Release either Shift key.", detail: "Wait for transcription; your words are pasted into the active app.")
            }

            Text("Grant the permissions and add your API key above to get started. Audio is sent to OpenAI for transcription using your key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private func usageStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)
            (Text(title).bold() + Text(" " + detail).foregroundColor(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func permissionStatus(
        title: String,
        enabled: Bool,
        openSettings: @escaping () -> Void
    ) -> some View {
        let checking = monitor.status == .checking
        let status = checking ? "Checking permission…" : (enabled ? "Permission granted" : "Permission not granted")
        let color: Color = checking ? .secondary : (enabled ? .green : .orange)

        return statusBubble(
            title: title, status: status, color: color,
            icon: checking ? "circle.dotted" : (enabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill"),
            buttonTitle: "Open System Settings", action: openSettings
        )
        .help(title == "Input Monitoring" && monitor.status == .unavailable
              ? "Permission is enabled, but keyboard monitoring could not start. Quit and reopen the app."
              : "\(title): \(status)")
    }

    private func statusBubble(
        title: String,
        status: String,
        color: Color,
        icon: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        bubble(title: title, status: status, color: color, icon: icon) {
            Button(action: action) {
                Text(buttonTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(minWidth: 130)
                    .background(color, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(buttonTitle)\(buttonTitle == "Open System Settings" ? " → \(title)" : " API Key")")
        }
    }

    private func bubble<Controls: View>(
        title: String, status: String, color: Color, icon: String,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        return HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout.weight(.medium))
                    .frame(width: 115, alignment: .leading)
                Text(status).font(.callout)
            }
            Spacer(minLength: 8)
            controls()
        }
        .foregroundStyle(color)
        .tint(color)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(color, lineWidth: 1)
        }
    }

}

#Preview {
    ContentView()
}
