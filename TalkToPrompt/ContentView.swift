import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = ShiftMonitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            Button("Play Beep") {
                monitor.playBeep()
            }
            .controlSize(.large)
            .accessibilityHint("Plays a one-second pure tone")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            permissionStatusBar
        }
        .frame(width: 720, height: 480)
        .onAppear { monitor.start() }
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
        .alert(alertTitle, isPresented: Binding(
            get: {
                monitor.showRestartConfirmation || monitor.playbackError != nil
                    || monitor.insertionError != nil || monitor.restartError != nil
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
                Text(monitor.restartError ?? monitor.insertionError ?? monitor.playbackError ?? "The action could not be completed.")
            }
        }
    }

    private var alertTitle: String {
        if monitor.showRestartConfirmation { return "Restart TalkToPrompt?" }
        if monitor.restartError != nil { return "Unable to Restart" }
        return monitor.insertionError == nil ? "Unable to Play Beep" : "Unable to Paste Text"
    }

    private func dismissAlert() {
        monitor.showRestartConfirmation = false
        monitor.playbackError = nil
        monitor.insertionError = nil
        monitor.restartError = nil
    }

    private var permissionStatusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                permissionStatus(
                    title: "Input Monitoring",
                    enabled: monitor.hasInputMonitoringPermission,
                    openSettings: { monitor.openInputMonitoringSettings() }
                )
                Divider().frame(height: 44)
                permissionStatus(
                    title: "Accessibility",
                    enabled: monitor.hasEventPostingPermission,
                    openSettings: { monitor.openAccessibilitySettings() }
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission status")
    }

    private func permissionStatus(
        title: String,
        enabled: Bool,
        openSettings: @escaping () -> Void
    ) -> some View {
        let checking = monitor.status == .checking
        let status = checking ? "Checking permission…" : (enabled ? "Permission granted" : "Permission not granted")

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: checking ? "circle.dotted" : (enabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                    .foregroundStyle(checking ? Color.secondary : (enabled ? .green : .orange))
                    .accessibilityHidden(true)
                Text(title).font(.caption.weight(.medium))
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Button("Open System Settings", action: openSettings)
                .font(.caption)
                .controlSize(.small)
                .help("Open \(title) settings")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(title == "Input Monitoring" && monitor.status == .unavailable
              ? "Permission is enabled, but keyboard monitoring could not start. Quit and reopen the app."
              : "\(title): \(status)")
    }

}

#Preview {
    ContentView()
}
