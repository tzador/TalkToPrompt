import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: ShiftMonitor
    @ObservedObject var apiKey: APIKeyModel
    @ObservedObject var onboarding: OnboardingModel
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
    @State private var showAPIKeyEntry = false
    var modalChanged: (Bool) -> Void = { _ in }
    var openSetup: () -> Void = {}
    var willOpenLoginSettings: () -> Void = {}

    var body: some View {
        NativeCalmView(state: .init(
            isReady: monitor.status == .monitoring && monitor.hasEventPostingPermission
                && monitor.microphone.authorization == .authorized && apiKey.isProvided && apiKey.errorMessage == nil,
            apiKeyStatus: apiKey.status, hasAPIKey: apiKey.isProvided,
            apiKeyUnavailable: apiKey.errorMessage != nil, needsSetup: !onboarding.hasCompleted,
            loginRequested: launchAtLogin.isRequested, loginNeedsApproval: launchAtLogin.needsApproval,
            loginStatus: launchAtLogin.statusText, loginError: launchAtLogin.errorMessage
        ), actions: .init(
            apiKey: { showAPIKeyEntry = true }, clearAPIKey: { apiKey.clear() }, setup: openSetup,
            setLogin: { launchAtLogin.setEnabled($0) },
            loginSettings: {
                willOpenLoginSettings()
                launchAtLogin.openLoginItemsSettings()
            }
        ))
        .onChange(of: showAPIKeyEntry || (!onboarding.isPresented && AppAlerts.hasNotice(monitor, apiKey)), initial: true) { _, showing in
            modalChanged(showing)
        }
        .sheet(isPresented: $showAPIKeyEntry) {
            APIKeyEntrySheet(onSave: { key in
                try await apiKey.save(key)
                showAPIKeyEntry = false
            }, onCancel: { showAPIKeyEntry = false })
        }
        .modifier(AppAlerts(monitor: monitor, apiKey: apiKey, onboarding: onboarding, inOnboarding: false))
    }
}

/// Only the currently active host presents notices; hidden popovers never own an alert.
struct AppAlerts: ViewModifier {
    @ObservedObject var monitor: ShiftMonitor
    @ObservedObject var apiKey: APIKeyModel
    @ObservedObject var onboarding: OnboardingModel
    let inOnboarding: Bool

    static func hasNotice(_ monitor: ShiftMonitor, _ apiKey: APIKeyModel) -> Bool {
        monitor.showRestartConfirmation || monitor.playbackError != nil || monitor.restartError != nil
            || apiKey.errorMessage != nil || monitor.microphone.errorMessage != nil || monitor.transcriptionError != nil
    }

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(
            get: { onboarding.isPresented == inOnboarding && Self.hasNotice(monitor, apiKey) },
            set: { if !$0 { dismiss() } }
        )) {
            if monitor.showRestartConfirmation {
                Button("Restart Now") { Task { await monitor.restart() } }
                Button("Not Now", role: .cancel) { monitor.showRestartConfirmation = false }
            } else {
                Button("OK", role: .cancel) { dismiss() }
            }
        } message: {
            if monitor.showRestartConfirmation {
                Text("macOS may need to restart TalkToPrompt after you enable \(monitor.restartPermissionName). If you enabled it, restart now to apply the change. Setup will resume at the next missing step.")
            } else {
                Text(monitor.restartError ?? apiKey.errorMessage ?? monitor.microphone.errorMessage
                     ?? monitor.transcriptionError ?? monitor.playbackError ?? "The action could not be completed.")
            }
        }
    }

    private var title: String {
        if monitor.showRestartConfirmation { return "Restart TalkToPrompt?" }
        if monitor.restartError != nil { return "Unable to Restart" }
        if apiKey.errorMessage != nil { return "Unable to Access API Key" }
        if monitor.microphone.errorMessage != nil { return "Unable to Record Audio" }
        if monitor.transcriptionError != nil { return "Unable to Transcribe or Paste" }
        return "Unable to Play Audio"
    }

    private func dismiss() {
        monitor.showRestartConfirmation = false
        monitor.playbackError = nil
        monitor.transcriptionError = nil
        monitor.restartError = nil
        apiKey.errorMessage = nil
        monitor.microphone.errorMessage = nil
    }
}
