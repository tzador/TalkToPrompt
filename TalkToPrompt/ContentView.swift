import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = ShiftMonitor()
    @StateObject private var apiKey = APIKeyModel()
    @State private var showAPIKeyEntry = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            Button("Play Beep") {
                monitor.playBeep()
            }
            .controlSize(.large)
            .accessibilityHint("Plays a one-second pure tone")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusPanel
        }
        .frame(width: 720, height: 720)
        .onAppear {
            monitor.start()
            apiKey.load()
        }
        .onDisappear { monitor.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                monitor.applicationActivated(bundleIdentifier: Bundle.main.bundleIdentifier)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
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
                Text("The app listens only for modifier-key changes. It does not record what you type.")
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
                    try apiKey.save(key)
                    showAPIKeyEntry = false
                },
                onCancel: { showAPIKeyEntry = false }
            )
        }
        .alert(alertTitle, isPresented: Binding(
            get: {
                monitor.showRestartConfirmation || monitor.playbackError != nil
                    || monitor.insertionError != nil || monitor.restartError != nil || apiKey.errorMessage != nil
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
                Text(monitor.restartError ?? apiKey.errorMessage ?? monitor.insertionError ?? monitor.playbackError ?? "The action could not be completed.")
            }
        }
    }

    private var alertTitle: String {
        if monitor.showRestartConfirmation { return "Restart TalkToPrompt?" }
        if monitor.restartError != nil { return "Unable to Restart" }
        if apiKey.errorMessage != nil { return "Unable to Access API Key" }
        return monitor.insertionError == nil ? "Unable to Play Beep" : "Unable to Paste Text"
    }

    private func dismissAlert() {
        monitor.showRestartConfirmation = false
        monitor.playbackError = nil
        monitor.insertionError = nil
        monitor.restartError = nil
        apiKey.errorMessage = nil
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
            }
            .padding(16)
            .background(.bar)
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App status")
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
