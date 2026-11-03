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

            permissionStatus
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(20)
        }
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { monitor.refreshPermission() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            monitor.stop()
        }
        .sheet(isPresented: $monitor.showPermissionExplanation) {
            VStack(spacing: 16) {
                Image(systemName: "keyboard")
                    .font(.largeTitle)
                Text("Enable the Shift Shortcut")
                    .font(.title2.bold())
                Text("Allow Input Monitoring to play a tone when you hold both Shift keys, even while using other apps. Releasing either key plays a higher tone.")
                Text("The app listens only for modifier-key changes. It does not record what you type.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Not Now", role: .cancel) {
                        monitor.showPermissionExplanation = false
                    }
                    Button("Enable Input Monitoring") {
                        monitor.requestPermission()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .frame(width: 420)
        }
        .alert("Unable to Play Beep", isPresented: Binding(
            get: { monitor.playbackError != nil },
            set: { if !$0 { monitor.playbackError = nil } }
        )) {
            Button("OK", role: .cancel) { monitor.playbackError = nil }
        } message: {
            Text(monitor.playbackError ?? "Audio playback failed.")
        }
    }

    @ViewBuilder
    private var permissionStatus: some View {
        switch monitor.status {
        case .checking:
            Text("Checking Input Monitoring access…")
                .foregroundStyle(.secondary)
        case .monitoring:
            Text("Hold both Shift keys for a tone.\nRelease either key for a higher tone.")
                .foregroundStyle(.secondary)
        case .needsPermission:
            VStack(spacing: 8) {
                Text("Enable TalkToPrompt in System Settings →\nPrivacy & Security → Input Monitoring.")
                HStack {
                    Button("Enable Input Monitoring") { monitor.requestPermission() }
                    Button("Open System Settings") { monitor.openInputMonitoringSettings() }
                }
            }
        case .unavailable:
            VStack(spacing: 8) {
                Text("Keyboard monitoring could not start.\nCheck Input Monitoring access, then quit and reopen the app.")
                Button("Open System Settings") { monitor.openInputMonitoringSettings() }
            }
        }
    }
}

#Preview {
    ContentView()
}
