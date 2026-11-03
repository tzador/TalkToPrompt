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
    @Published var showPermissionExplanation = false
    @Published var playbackError: String?

    private let beepPlayer = BeepPlayer()
    private var chord = ShiftChordState()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private let defaults: UserDefaults
    private let checkPermission: () -> Bool
    private let requestAccess: () -> Bool
    private static let requestedPermissionKey = "hasRequestedInputMonitoring"

    init(
        defaults: UserDefaults = .standard,
        checkPermission: @escaping () -> Bool = CGPreflightListenEventAccess,
        requestAccess: @escaping () -> Bool = CGRequestListenEventAccess
    ) {
        self.defaults = defaults
        self.checkPermission = checkPermission
        self.requestAccess = requestAccess
    }

    func start() {
        guard !started else { return }
        started = true
        refreshPermission()
        if status == .needsPermission && !defaults.bool(forKey: Self.requestedPermissionKey) {
            showPermissionExplanation = true
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
    }

    func stop() {
        started = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        stopTap()
        status = .checking
    }

    func requestPermission() {
        showPermissionExplanation = false
        defaults.set(true, forKey: Self.requestedPermissionKey)
        _ = requestAccess()
        refreshPermission()
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    func refreshPermission() {
        guard started else { return }
        guard checkPermission() else {
            stopTap()
            status = .needsPermission
            return
        }
        showPermissionExplanation = false
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
            // Generating or starting audio must not delay the event callback.
            Task { @MainActor [weak self] in
                guard let self, self.started, self.status == .monitoring else { return }
                self.playBeep(pressed ? .pressed : .released)
            }
        }
    }

    private func stopTap() {
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
