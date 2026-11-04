import Combine
import ServiceManagement

/// Uses the system's registration as the source of truth, including approval changes.
@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published var errorMessage: String?
    private let checkStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let openSettings: () -> Void

    init(
        checkStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() },
        openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.checkStatus = checkStatus
        self.register = register
        self.unregister = unregister
        self.openSettings = openSettings
        refresh()
    }

    var isEnabled: Bool { status == .enabled }
    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }
    var statusText: String {
        switch status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Disabled"
        case .requiresApproval: return "Needs approval"
        case .notFound: return "Unavailable"
        @unknown default: return "Unavailable"
        }
    }

    func refresh() { status = checkStatus() }

    func setEnabled(_ enabled: Bool) {
        refresh()
        guard enabled != isRequested else { return }
        do {
            if enabled { try register() }
            else { try unregister() }
            errorMessage = nil
        } catch {
            errorMessage = "Could not \(enabled ? "enable" : "disable") launch at login. \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() { openSettings() }
}
