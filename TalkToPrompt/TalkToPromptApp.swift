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
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let monitor = ShiftMonitor()
    let apiKey = APIKeyModel()
    let launchAtLogin = LaunchAtLoginModel()
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
            monitor: monitor, apiKey: apiKey, launchAtLogin: launchAtLogin,
            modalChanged: { [weak self] showing in
                self?.showingModal = showing
                self?.popover.behavior = showing ? .applicationDefined : .transient
            },
            willOpenSystemSettings: { [weak self] in
                self?.showingModal = false
                self?.popover.behavior = .transient
                self?.popover.close()
            }
        ))
        for publisher in [monitor.objectWillChange.eraseToAnyPublisher(),
                          apiKey.objectWillChange.eraseToAnyPublisher(),
                          launchAtLogin.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in
                // Read updated values after ObservableObject's pre-mutation notification.
                DispatchQueue.main.async { [weak self] in self?.refreshStatus() }
            }.store(in: &observations)
        }
        apiKey.load()
        launchAtLogin.refresh()
        monitor.start()
        refreshStatus()
        if !UserDefaults.standard.bool(forKey: "hasShownMenuBarSetup") {
            UserDefaults.standard.set(true, forKey: "hasShownMenuBarSetup")
            showPopover()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        launchAtLogin.refresh()
        monitor.applicationActivated(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
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
        if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
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
        let notice = [monitor.restartError, monitor.playbackError, monitor.transcriptionError,
                      monitor.microphone.errorMessage, apiKey.errorMessage, launchAtLogin.errorMessage,
                      monitor.showRestartConfirmation ? "restart" : nil,
                      monitor.showPermissionExplanation ? "permissions" : nil]
            .compactMap { $0 }.joined(separator: "\n")
        if notice.isEmpty { presentedNotice = nil }
        else if presentedNotice != notice {
            presentedNotice = notice
            showPopover() // Surface errors and restart prompts even while settings are closed.
        }
    }
}
