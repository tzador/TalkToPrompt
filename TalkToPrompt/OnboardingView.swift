import SwiftUI

@MainActor
struct OnboardingView: View {
    @ObservedObject var onboarding: OnboardingModel
    @ObservedObject var monitor: ShiftMonitor
    @ObservedObject var apiKey: APIKeyModel
    var openSettings: (@escaping () -> Void) -> Void
    var complete: () -> Void
    @State private var showAPIKeyEntry = false
    @State private var requestingMicrophone = false
    @State private var testText = ""
    @FocusState private var testFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                if let image = MenuBarIcon.statusImage() {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 30, height: 28)
                }
                Text("Set up TalkToPrompt").font(.title2.weight(.semibold))
                Spacer()
                Text("Step \(onboarding.step.rawValue + 1) of 5").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    Capsule().fill(step.rawValue <= onboarding.step.rawValue ? NativeCalmPalette.green : Color.primary.opacity(0.1))
                        .frame(height: 4)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: onboarding.step.symbol)
                    .font(.system(size: 32, weight: .regular)).foregroundStyle(.secondary)
                    .frame(height: 40)
                Text(onboarding.step.title).font(.system(size: 26, weight: .semibold))
                stepContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Button("Quit TalkToPrompt") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                primaryAction
            }
        }
        .padding(28)
        .frame(width: 580, height: 550)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: onboarding.step) { testFocused = onboarding.step == .test }
        .sheet(isPresented: $showAPIKeyEntry) {
            APIKeyEntrySheet(onSave: { key in
                try await apiKey.save(key)
                showAPIKeyEntry = false
            }, onCancel: { showAPIKeyEntry = false })
        }
        .modifier(AppAlerts(monitor: monitor, apiKey: apiKey, onboarding: onboarding, inOnboarding: true))
    }

    @ViewBuilder private var stepContent: some View {
        switch onboarding.step {
        case .accessibility:
            explanation("Paste your words where you're working.",
                        detail: "Accessibility permission lets TalkToPrompt send the Paste shortcut to the app you're typing in. It does not read your documents or control your other apps beyond pasting your transcript.")
            settingsInstructions("Accessibility")
        case .inputMonitoring:
            explanation("Hold both Shift keys to speak, from any app.",
                        detail: "Input Monitoring lets TalkToPrompt detect the left and right Shift keys together, even when another app has focus. It watches Shift-key changes, not the text you type.")
            if monitor.status == .unavailable {
                Text("Permission is enabled, but monitoring hasn't started. Restart TalkToPrompt to apply it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else { settingsInstructions("Input Monitoring") }
        case .microphone:
            explanation("Let TalkToPrompt hear you when you dictate.",
                        detail: "Click Allow Microphone, then Allow in the macOS prompt. This step only requests permission; it does not record anything. Recording starts when you hold both Shift keys.")
            if monitor.microphone.authorization == .denied || monitor.microphone.authorization == .restricted {
                Text("Microphone access was not allowed. Enable TalkToPrompt in System Settings → Privacy & Security → Microphone to continue.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .apiKey:
            explanation("Your recordings go directly to OpenAI.",
                        detail: "TalkToPrompt keeps audio in memory and never saves audio files or routes it through our servers. OpenAI receives the recording to transcribe it, under its own data policies.")
            Text("Bring your own OpenAI API key. It is validated before being saved in this app's macOS Keychain item. API usage is billed by OpenAI. If you select a translation language, the transcript is also sent to OpenAI for translation.")
                .font(.callout).foregroundStyle(.secondary)
            Text("By connecting a key and using dictation, you choose to send your recordings directly to OpenAI for transcription.")
                .font(.caption).foregroundStyle(.secondary)
        case .test:
            explanation("Try your first dictation.",
                        detail: "Click the field below, hold left Shift + right Shift, say a sentence, then release either key. Your words will appear here after transcription.")
            TextEditor(text: $testText)
                .font(.body).focused($testFocused)
                .padding(8)
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)) }
                .accessibilityLabel("Try dictation here")
            Text("Testing is optional and uses your OpenAI API balance. When you're done, TalkToPrompt stays in the menu bar and works in other apps too.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func explanation(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsInstructions(_ permission: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Open Privacy & Security → \(permission).", systemImage: "1.circle")
            Label("Enable TalkToPrompt in the list.", systemImage: "2.circle")
            Label("Restart when asked. Setup will pick up where you left off.", systemImage: "3.circle")
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var primaryAction: some View {
        switch onboarding.step {
        case .accessibility:
            Button("Open System Settings") { openSettings { monitor.openAccessibilitySettings() } }
                .buttonStyle(.borderedProminent)
        case .inputMonitoring:
            if monitor.status == .unavailable {
                Button("Restart Now") { Task { await monitor.restart() } }.buttonStyle(.borderedProminent)
            } else {
                Button("Open System Settings") { openSettings { monitor.openInputMonitoringSettings() } }
                    .buttonStyle(.borderedProminent)
            }
        case .microphone:
            Button(requestingMicrophone ? "Requesting…" : (monitor.microphone.authorization == .notDetermined ? "Allow Microphone" : "Open System Settings")) {
                if monitor.microphone.authorization == .notDetermined {
                    requestingMicrophone = true
                    Task { @MainActor in
                        await monitor.microphone.requestPermission()
                        requestingMicrophone = false
                    }
                } else { openSettings { Task { await monitor.microphone.openSettings() } } }
            }
            .buttonStyle(.borderedProminent).disabled(requestingMicrophone)
        case .apiKey:
            Button("Enter OpenAI API Key") { showAPIKeyEntry = true }.buttonStyle(.borderedProminent)
        case .test:
            Button("Finish Setup", action: complete).buttonStyle(.borderedProminent)
        }
    }
}
