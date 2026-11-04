import AppKit

/// Temporarily changes the running app's Dock tile, without changing its saved icon.
@MainActor
final class DockIconController {
    enum State: Equatable {
        case ready, missingRequirements

        static func permissions(inputMonitoring: Bool, accessibility: Bool, microphone: Bool, apiKey: Bool) -> State {
            inputMonitoring && accessibility && microphone && apiKey ? .ready : .missingRequirements
        }

        var assetName: String {
            self == .ready ? "DockIconReady" : "DockIconMissing"
        }
    }

    private let loadImage: @MainActor (String) -> NSImage?
    private let applyImage: @MainActor (NSImage?) -> Void
    private var images: [String: NSImage] = [:]
    private var currentState: State?

    init(
        loadImage: @escaping @MainActor (String) -> NSImage? = { bundledImage(named: $0) },
        applyImage: @escaping @MainActor (NSImage?) -> Void = { NSApplication.shared.applicationIconImage = $0 }
    ) {
        self.loadImage = loadImage
        self.applyImage = applyImage
    }

    static func bundledImage(named name: String, bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.url(forResource: name, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    func update(_ state: State) {
        guard currentState != state else { return }
        let name = state.assetName
        guard let image = images[name] ?? loadImage(name) else { return }
        images[name] = image
        applyImage(image)
        currentState = state
    }

    func restore() {
        guard currentState != nil else { return }
        applyImage(nil)
        currentState = nil
    }
}
