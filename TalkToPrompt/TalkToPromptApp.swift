import AppKit
import Combine
import SwiftUI

@main
struct TalkToPromptApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns monitoring independently of the transient settings popover.
@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let monitor = ShiftMonitor()
    let apiKey = APIKeyModel()
    let onboarding = OnboardingModel()
    let launchAtLogin = LaunchAtLoginModel()
    private var setupWindow: NSWindow?
    private var waitingForSettings = false
    private(set) var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var observations: Set<AnyCancellable> = []
    private var presentedNotice: String?
    private var showingModal = false
    private var iconState: MenuBarIcon.State?
    private let readinessIndicator = MenuBarIcon.ReadinessIndicator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tests host the app but should not install a menu item or request permissions.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.setAccessibilityLabel("TalkToPrompt")
        item.button?.image = MenuBarIcon.statusImage()
        if let button = item.button {
            readinessIndicator.translatesAutoresizingMaskIntoConstraints = false
            readinessIndicator.setAccessibilityElement(false)
            button.addSubview(readinessIndicator)
            NSLayoutConstraint.activate([
                readinessIndicator.widthAnchor.constraint(equalToConstant: 8),
                readinessIndicator.heightAnchor.constraint(equalToConstant: 8),
                readinessIndicator.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                readinessIndicator.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3)
            ])
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView(
            monitor: monitor, apiKey: apiKey, onboarding: onboarding, launchAtLogin: launchAtLogin,
            modalChanged: { [weak self] showing in
                self?.showingModal = showing
                self?.popover.behavior = showing ? .applicationDefined : .transient
            },
            openSetup: { [weak self] in
                guard let self else { return }
                self.onboarding.begin(requirements: self.requirements, force: true)
                self.popover.close()
                self.showSetupWindow()
            },
            willOpenLoginSettings: { [weak self] in
                self?.popover.close()
            }
        ))
        for publisher in [monitor.objectWillChange.eraseToAnyPublisher(),
                          apiKey.objectWillChange.eraseToAnyPublisher(),
                          onboarding.objectWillChange.eraseToAnyPublisher(),
                          launchAtLogin.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in
                // Read updated values after ObservableObject's pre-mutation notification.
                DispatchQueue.main.async { [weak self] in self?.refreshStatus() }
            }.store(in: &observations)
        }
        apiKey.load()
        monitor.allowsDictation = onboarding.hasCompleted
        monitor.start(showPermissionExplanation: false)
        onboarding.begin(requirements: requirements)
        refreshStatus()
        if onboarding.isPresented { showSetupWindow() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        launchAtLogin.refresh()
        monitor.applicationActivated(bundleIdentifier: Bundle.main.bundleIdentifier)
        if onboarding.isPresented {
            waitingForSettings = false
            showSetupWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        waitingForSettings = false
        if !onboarding.hasCompleted {
            onboarding.begin(requirements: requirements, force: true)
            showSetupWindow()
        } else { showPopover() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        observations.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool { !showingModal }

    @objc private func togglePopover() {
        waitingForSettings = false
        if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    private func showPopover() {
        if onboarding.isPresented { showSetupWindow(); return }
        guard let button = statusItem?.button else { return }
        launchAtLogin.refresh()
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func refreshStatus() {
        let state = MenuBarIcon.State.permissions(
            inputMonitoring: monitor.status == .monitoring,
            accessibility: monitor.hasEventPostingPermission,
            microphone: monitor.microphone.authorization == .authorized,
            apiKey: apiKey.isProvided && apiKey.errorMessage == nil
        )
        if iconState != state {
            readinessIndicator.state = state
            iconState = state
        }
        statusItem?.button?.toolTip = state == .ready ? "TalkToPrompt — Ready" : "TalkToPrompt — Setup required"
        onboarding.synchronize(requirements: requirements, awaitingRestart: monitor.showRestartConfirmation)
        monitor.allowsDictation = !onboarding.isPresented || onboarding.step == .test
        let notice = [monitor.restartError, monitor.playbackError, monitor.transcriptionError,
                      monitor.microphone.errorMessage, apiKey.errorMessage,
                      monitor.showRestartConfirmation ? "restart" : nil]
            .compactMap { $0 }.joined(separator: "\n")
        if notice.isEmpty { presentedNotice = nil }
        else if presentedNotice != notice {
            presentedNotice = notice
            waitingForSettings = false
            if onboarding.isPresented { showSetupWindow() }
            else { showPopover() }
        }
    }

    private var requirements: OnboardingModel.Requirements {
        .init(accessibility: monitor.hasEventPostingPermission,
              inputMonitoring: monitor.status == .monitoring,
              microphone: monitor.microphone.authorization == .authorized,
              apiKey: apiKey.isProvided && apiKey.errorMessage == nil)
    }

    private func showSetupWindow() {
        guard !waitingForSettings else { return }
        popover.close()
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 550),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Set up TalkToPrompt"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.contentViewController = NSHostingController(rootView: OnboardingView(
                onboarding: onboarding, monitor: monitor, apiKey: apiKey,
                openSettings: { [weak self] action in
                    self?.waitingForSettings = true
                    self?.setupWindow?.orderOut(nil)
                    action()
                },
                complete: { [weak self] in
                    guard let self else { return }
                    self.onboarding.complete(requirements: self.requirements)
                    if !self.onboarding.isPresented { self.setupWindow?.orderOut(nil) }
                }
            ))
            window.center()
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === setupWindow else { return }
        onboarding.dismiss() // Closing early does not mark setup complete.
    }

}
