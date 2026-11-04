import AppKit
import Combine
import CoreGraphics
import IOKit.hidsystem

/// Emits an edge only when the two-key chord changes, in either key order.
struct ShiftChordState {
    private(set) var bothPressed = false

    mutating func update(leftPressed: Bool, rightPressed: Bool) -> Bool? {
        let newValue = leftPressed && rightPressed
        guard newValue != bothPressed else { return nil }
        bothPressed = newValue
        return newValue
    }

    mutating func synchronize(leftPressed: Bool, rightPressed: Bool) {
        bothPressed = leftPressed && rightPressed
    }
}

@MainActor
final class ShiftMonitor: ObservableObject {
    enum Status: Equatable {
        case checking
        case needsPermission
        case monitoring
        case unavailable
    }

    @Published private(set) var status: Status = .checking
    @Published private(set) var hasEventPostingPermission = false
    @Published var showPermissionExplanation = false
    @Published var playbackError: String?
    @Published var transcriptionError: String?
    @Published var showRestartConfirmation = false
    @Published var restartError: String?
    @Published private(set) var isRestarting = false
    var allowsDictation = true {
        didSet {
            if oldValue && !allowsDictation { voiceSession.stopImmediately() }
        }
    }
    let microphone: MicrophoneRecordingSession
    private var microphoneObservation: AnyCancellable?

    private let beepPlayer = BeepPlayer()
    private let desktopOverlay = DesktopOverlayController()
    private let textInserter = ClipboardTextInserter()
    private lazy var voiceSession = VoiceSessionController(
        microphone: microphone, overlay: desktopOverlay, transcriber: OpenAITranscriber(),
        loadAPIKey: { try KeychainAPIKeyStore().load() },
        insertText: { [weak self] text in try await self?.textInserter.insert(text) },
        restoreClipboard: { [weak self] in _ = self?.textInserter.restorePendingClipboard() },
        onBegin: { [weak self] in self?.playBeep(.pressed) },
        onExit: { [weak self] in self?.playBeep(.released) },
        onError: { [weak self] error in
            self?.transcriptionError = error
            NSApp.activate(ignoringOtherApps: true)
        }
    )
    private var chord = ShiftChordState()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapGeneration = UUID()
    private var permissionTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var awaitingAccessibilitySettingsReturn = false
    private var visitedAccessibilitySettings = false
    private var awaitingInputSettingsReturn = false
    private var visitedInputSettings = false
    private var previousInputPermission: Bool?
    private var previousPostingPermission: Bool?
    @Published private(set) var restartPermissionName = "Keyboard permissions"
    private var explainsStartupPermissions = true
    private var started = false
    private let defaults: UserDefaults
    private let checkPermission: () -> Bool
    private let requestAccess: () -> Bool
    private let checkEventPostingPermission: () -> Bool
    private let requestEventPostingAccess: () -> Bool
    private let openSettings: (String) -> Void
    private let frontmostBundleIdentifier: () -> String?
    private let launchNewInstance: @MainActor () async throws -> Void
    private let terminateCurrentInstance: @MainActor () -> Void
    private static let requestedPermissionKey = "hasRequestedInputMonitoring"
    private static let requestedEventPostingKey = "hasRequestedEventPosting"

    var hasInputMonitoringPermission: Bool {
        status == .monitoring || status == .unavailable
    }

    init(
        defaults: UserDefaults = .standard,
        checkPermission: @escaping () -> Bool = CGPreflightListenEventAccess,
        requestAccess: @escaping () -> Bool = CGRequestListenEventAccess,
        checkEventPostingPermission: @escaping () -> Bool = CGPreflightPostEventAccess,
        requestEventPostingAccess: @escaping () -> Bool = CGRequestPostEventAccess,
        openSettings: @escaping (String) -> Void = { pane in
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
            if !NSWorkspace.shared.open(url) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            }
        },
        frontmostBundleIdentifier: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        launchNewInstance: @escaping @MainActor () async throws -> Void = {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        },
        terminateCurrentInstance: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
        microphone: MicrophoneRecordingSession? = nil
    ) {
        self.defaults = defaults
        self.checkPermission = checkPermission
        self.requestAccess = requestAccess
        self.checkEventPostingPermission = checkEventPostingPermission
        self.requestEventPostingAccess = requestEventPostingAccess
        self.openSettings = openSettings
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.launchNewInstance = launchNewInstance
        self.terminateCurrentInstance = terminateCurrentInstance
        self.microphone = microphone ?? MicrophoneRecordingSession()
        microphoneObservation = self.microphone.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func start(showPermissionExplanation: Bool = true) {
        guard !started else { return }
        explainsStartupPermissions = showPermissionExplanation
        started = true
        refreshPermission()
        let explainInputMonitoring = status == .needsPermission
            && !defaults.bool(forKey: Self.requestedPermissionKey)
        let explainEventPosting = !hasEventPostingPermission
            && !defaults.bool(forKey: Self.requestedEventPostingKey)
        if explainsStartupPermissions && (explainInputMonitoring || explainEventPosting) {
            self.showPermissionExplanation = true
        }

        // Also notice revocation while another app is in focus.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermission() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopTap()
                self?.refreshPermission()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = application?.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.applicationActivated(bundleIdentifier: bundleIdentifier)
            }
        }
    }

    func stop() {
        started = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        awaitingAccessibilitySettingsReturn = false
        visitedAccessibilitySettings = false
        awaitingInputSettingsReturn = false
        visitedInputSettings = false
        previousInputPermission = nil
        previousPostingPermission = nil
        stopTap()
        desktopOverlay.stop()
        status = .checking
    }

    func requestPermission() {
        showPermissionExplanation = false
        defaults.set(true, forKey: Self.requestedPermissionKey)
        _ = requestAccess()
        refreshPermission()
    }

    func openInputMonitoringSettings() {
        // Register the app with macOS if needed, then always open Settings,
        // including when the system no longer displays another consent prompt.
        if !checkPermission() {
            awaitingInputSettingsReturn = true
            visitedInputSettings = false
            requestPermission()
        }
        openPrivacySettings("Privacy_ListenEvent")
        applicationActivated(bundleIdentifier: frontmostBundleIdentifier())
    }

    func requestEventPostingPermission() {
        showPermissionExplanation = false
        defaults.set(true, forKey: Self.requestedEventPostingKey)
        _ = requestEventPostingAccess()
        refreshPermission()
    }

    func openAccessibilitySettings() {
        if !checkEventPostingPermission() {
            awaitingAccessibilitySettingsReturn = true
            visitedAccessibilitySettings = false
            requestEventPostingPermission()
        }
        openPrivacySettings("Privacy_Accessibility")
        // Settings may already have been frontmost when its button was clicked.
        applicationActivated(bundleIdentifier: frontmostBundleIdentifier())
    }

    private func openPrivacySettings(_ pane: String) {
        openSettings(pane)
    }

    func applicationActivated(bundleIdentifier: String?) {
        guard started else { return }
        if bundleIdentifier == "com.apple.systempreferences" {
            if awaitingAccessibilitySettingsReturn { visitedAccessibilitySettings = true }
            if awaitingInputSettingsReturn { visitedInputSettings = true }
        }
        guard bundleIdentifier == Bundle.main.bundleIdentifier else { return }
        refreshPermission()
        if awaitingAccessibilitySettingsReturn && visitedAccessibilitySettings {
            awaitingAccessibilitySettingsReturn = false
            visitedAccessibilitySettings = false
            // The permission check can stay false until relaunch, even after
            // the user has enabled the toggle. Offer a restart in either case.
            restartPermissionName = "Accessibility"
            showRestartConfirmation = true
        }
        if awaitingInputSettingsReturn && visitedInputSettings {
            awaitingInputSettingsReturn = false
            visitedInputSettings = false
            restartPermissionName = "Input Monitoring"
            showRestartConfirmation = true
        }
    }

    func restart() async {
        guard !isRestarting else { return }
        isRestarting = true
        showRestartConfirmation = false
        stop() // Restore the clipboard before launching another instance.
        do {
            try await launchNewInstance()
            terminateCurrentInstance()
        } catch {
            isRestarting = false
            start(showPermissionExplanation: explainsStartupPermissions)
            restartError = "TalkToPrompt could not restart: \(error.localizedDescription). Quit and reopen the app manually."
        }
    }

    func refreshPermission() {
        guard started else { return }
        microphone.refreshPermission()
        // Posting and listening are independent permissions. Missing posting
        // access must not prevent the Shift tones from working.
        let postingGranted = checkEventPostingPermission()
        let inputGranted = checkPermission()
        // Notice grants even while System Settings remains frontmost. A first
        // check on launch establishes a baseline and must never request a restart.
        if previousPostingPermission == false && postingGranted {
            awaitingAccessibilitySettingsReturn = false
            visitedAccessibilitySettings = false
            restartPermissionName = "Accessibility"
            showRestartConfirmation = true
        }
        if previousInputPermission == false && inputGranted {
            awaitingInputSettingsReturn = false
            visitedInputSettings = false
            restartPermissionName = "Input Monitoring"
            showRestartConfirmation = true
        }
        previousPostingPermission = postingGranted
        previousInputPermission = inputGranted
        hasEventPostingPermission = postingGranted
        guard inputGranted else {
            stopTap()
            status = .needsPermission
            return
        }
        if hasEventPostingPermission { showPermissionExplanation = false }
        if let eventTap, CGEvent.tapIsEnabled(tap: eventTap) {
            status = .monitoring
            return
        }
        stopTap()
        startTap()
    }

    func playBeep(_ tone: BeepPlayer.Tone = .pressed) {
        do {
            try beepPlayer.play(tone)
        } catch {
            playbackError = error.localizedDescription
        }
    }

    private func startTap() {
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ShiftMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                let flags = event.flags.rawValue
                // This tap is attached exclusively to the main run loop. Read
                // edges synchronously so queued events cannot outlive the tap.
                MainActor.assumeIsolated {
                    monitor.receive(type: type, flags: flags)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status = .unavailable
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            status = .unavailable
            return
        }
        eventTap = tap
        runLoopSource = source
        // Do not invent a press/release if monitoring begins with Shift already held.
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        chord.synchronize(
            leftPressed: flags & UInt64(NX_DEVICELSHIFTKEYMASK) != 0,
            rightPressed: flags & UInt64(NX_DEVICERSHIFTKEYMASK) != 0
        )
        desktopOverlay.start()
        if allowsDictation && chord.bothPressed { voiceSession.begin() }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        status = .monitoring
    }

    private func receive(type: CGEventType, flags: UInt64) {
        guard started, eventTap != nil else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Recreate the tap and synchronize after an interruption.
            stopTap()
            refreshPermission()
            return
        }
        guard type == .flagsChanged else { return }
        // The generic .maskShift flag combines both keys. These public device
        // flags preserve which physical Shift keys are held in each event.
        if let pressed = chord.update(
            leftPressed: flags & UInt64(NX_DEVICELSHIFTKEYMASK) != 0,
            rightPressed: flags & UInt64(NX_DEVICERSHIFTKEYMASK) != 0
        ) {
            let generation = tapGeneration
            // Window and audio work must not delay the event callback.
            Task { @MainActor [weak self] in
                guard let self, self.started, self.status == .monitoring,
                      self.tapGeneration == generation else { return }
                if pressed {
                    if self.allowsDictation && self.chord.bothPressed { self.voiceSession.begin() }
                } else {
                    self.voiceSession.finish()
                }
            }
        }
    }

    private func stopTap() {
        tapGeneration = UUID()
        voiceSession.stopImmediately()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        chord = ShiftChordState()
    }
}
