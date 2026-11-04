import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: ShiftMonitor
    @ObservedObject var apiKey: APIKeyModel
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
    @State private var showAPIKeyEntry = false
    var modalChanged: (Bool) -> Void = { _ in }
    var willOpenSystemSettings: () -> Void = {}

    var body: some View {
        NativeCalmView(state: nativeCalmState, actions: .init(
            inputMonitoring: { openSettings { monitor.openInputMonitoringSettings() } },
            accessibility: { openSettings { monitor.openAccessibilitySettings() } },
            microphone: { openSettings { Task { await monitor.microphone.openSettings() } } },
            apiKey: { showAPIKeyEntry = true },
            setLogin: { launchAtLogin.setEnabled($0) },
            loginSettings: { openSettings { launchAtLogin.openLoginItemsSettings() } },
            clearAPIKey: { apiKey.clear() }
        ))
        .onChange(of: hasModal, initial: true) { _, showing in
            modalChanged(showing)
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
                        Button("Open System Settings") { openSettings { monitor.openInputMonitoringSettings() } }
                            .help("Open Input Monitoring settings")
                    }
                    if monitor.hasEventPostingPermission {
                        Label("Accessibility: Permission granted", systemImage: "checkmark.circle")
                    } else {
                        Button("Open System Settings") { openSettings { monitor.openAccessibilitySettings() } }
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

    private func openSettings(_ action: () -> Void) {
        monitor.showPermissionExplanation = false
        willOpenSystemSettings()
        action()
    }

    private var hasModal: Bool {
        showAPIKeyEntry || monitor.showPermissionExplanation || monitor.showRestartConfirmation
            || monitor.playbackError != nil || monitor.restartError != nil || apiKey.errorMessage != nil
            || monitor.microphone.errorMessage != nil || monitor.transcriptionError != nil
            || launchAtLogin.errorMessage != nil
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

    private var nativeCalmState: NativeCalmState {
        let checking = monitor.status == .checking
        return NativeCalmState(
            inputMonitoring: checking ? .checking : (monitor.status == .unavailable ? .restartRequired : (monitor.hasInputMonitoringPermission ? .granted : .missing)),
            accessibility: checking ? .checking : (monitor.hasEventPostingPermission ? .granted : .missing),
            microphone: monitor.microphone.authorization == .authorized ? .granted : .missing,
            apiKeyStatus: apiKey.status,
            hasAPIKey: apiKey.isProvided,
            apiKeyUnavailable: apiKey.errorMessage != nil,
            loginStatus: launchAtLogin.statusText,
            loginRequested: launchAtLogin.isRequested,
            loginNeedsApproval: launchAtLogin.needsApproval,
            loginUnavailable: launchAtLogin.status == .notFound
        )
    }
}

#Preview {
    ContentView(monitor: ShiftMonitor(), apiKey: APIKeyModel(), launchAtLogin: LaunchAtLoginModel())
}
