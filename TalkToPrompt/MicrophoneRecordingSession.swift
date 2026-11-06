import AppKit
import AVFoundation
import Combine

@MainActor
final class MicrophoneRecordingSession: ObservableObject {
    @Published private(set) var authorization: AVAuthorizationStatus
    @Published private(set) var isRecording = false
    @Published var errorMessage: String?
    private(set) var latestRecording: MicrophoneRecording?

    var onPermissionPrompt: (() -> Void)?
    var onFirstAudio: (() -> Void)?
    var onIntensities: (([Float]) -> Void)?
    var onFailure: (() -> Void)?

    private let capture: MicrophoneCapturing
    private let checkAuthorization: () -> AVAuthorizationStatus
    private let requestAccess: () async -> Bool
    private var activeID: UUID?
    private var latestID: UUID?
    private var requestedCaptures: Set<UUID> = []
    private var beginTask: Task<Void, Never>?
    private var finishTask: Task<MicrophoneRecording?, Never>?

    init(
        capture: MicrophoneCapturing = MicrophoneRecorder(),
        checkAuthorization: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        requestAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    ) {
        self.capture = capture
        self.checkAuthorization = checkAuthorization
        self.requestAccess = requestAccess
        authorization = checkAuthorization()
    }

    func refreshPermission() {
        authorization = checkAuthorization()
        if (authorization == .denied || authorization == .restricted), activeID != nil {
            finish()
            onFailure?()
        }
    }

    func begin() {
        guard activeID == nil else { return }
        let id = UUID()
        activeID = id
        latestID = id
        latestRecording = nil
        finishTask = nil
        errorMessage = nil
        isRecording = false
        authorization = checkAuthorization()
        beginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.authorization == .notDetermined {
                    // Make the system consent dialog readable above the desktop.
                    self.onPermissionPrompt?()
                    _ = await self.requestAccess()
                    self.authorization = self.checkAuthorization()
                }
                try Task.checkCancellation()
                guard self.activeID == id else { return }
                guard self.authorization == .authorized else { throw PermissionError.accessRequired }
                self.requestedCaptures.insert(id)
                try await self.capture.start(id: id, onFirstAudio: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeID == id else { return }
                        self.isRecording = true
                        self.onFirstAudio?()
                    }
                }, onFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeID == id else { return }
                        self.finish()
                        self.errorMessage = message
                        self.onFailure?()
                    }
                }, onIntensities: { [weak self] values in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeID == id else { return }
                        self.onIntensities?(values)
                    }
                })
            } catch is CancellationError {
                // A released chord must never resume recording after consent.
            } catch {
                self.requestedCaptures.remove(id)
                guard self.activeID == id else { return }
                self.activeID = nil
                self.isRecording = false
                self.errorMessage = error.localizedDescription
                self.onFailure?()
            }
        }
    }

    @discardableResult
    func finish() -> Task<MicrophoneRecording?, Never>? {
        guard let id = activeID else { return finishTask }
        activeID = nil
        beginTask?.cancel()
        beginTask = nil
        isRecording = false
        guard requestedCaptures.remove(id) != nil else { return nil }
        let task = Task { @MainActor [weak self, capture] in
            let recording = await capture.stop(id: id)
            if let self, self.latestID == id { self.latestRecording = recording }
            return recording
        }
        finishTask = task
        return task
    }

    /// Requests consent without opening the capture device or starting a recording.
    func requestPermission() async {
        if checkAuthorization() == .notDetermined { _ = await requestAccess() }
        refreshPermission()
    }

    func openSettings() async {
        await requestPermission()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    enum PermissionError: LocalizedError {
        case accessRequired
        var errorDescription: String? {
            "Enable TalkToPrompt in System Settings → Privacy & Security → Microphone, then hold both Shift keys again."
        }
    }
}
