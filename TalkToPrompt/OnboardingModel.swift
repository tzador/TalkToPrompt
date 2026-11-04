import Combine
import Foundation

/// Persists completion, never individual permission grants (macOS remains their source of truth).
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case accessibility, inputMonitoring, microphone, apiKey, test

        var title: String {
            switch self {
            case .accessibility: return "Allow text insertion"
            case .inputMonitoring: return "Enable your shortcut"
            case .microphone: return "Allow microphone access"
            case .apiKey: return "Connect to OpenAI"
            case .test: return "You're ready to talk"
            }
        }

        var symbol: String {
            switch self {
            case .accessibility: return "accessibility"
            case .inputMonitoring: return "keyboard"
            case .microphone: return "mic"
            case .apiKey: return "key"
            case .test: return "checkmark.circle"
            }
        }
    }

    struct Requirements: Equatable {
        var accessibility: Bool
        var inputMonitoring: Bool
        var microphone: Bool
        var apiKey: Bool

        var firstIncomplete: Step {
            if !accessibility { return .accessibility }
            if !inputMonitoring { return .inputMonitoring }
            if !microphone { return .microphone }
            if !apiKey { return .apiKey }
            return .test
        }
    }

    static let completionKey = "hasCompletedOnboarding"
    @Published private(set) var step: Step = .accessibility
    @Published private(set) var isPresented = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var hasCompleted: Bool { defaults.bool(forKey: Self.completionKey) }

    func begin(requirements: Requirements, force: Bool = false) {
        guard force || !hasCompleted || requirements.firstIncomplete != .test else { return }
        step = requirements.firstIncomplete
        isPresented = true
    }

    func synchronize(requirements: Requirements, awaitingRestart: Bool) {
        guard isPresented, !awaitingRestart else { return }
        if step != requirements.firstIncomplete { step = requirements.firstIncomplete }
    }

    func dismiss() { isPresented = false }

    func complete(requirements: Requirements) {
        guard requirements.firstIncomplete == .test else { return }
        defaults.set(true, forKey: Self.completionKey)
        isPresented = false
    }
}
