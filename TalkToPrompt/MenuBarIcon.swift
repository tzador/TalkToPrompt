import AppKit

/// Reuses the app's microphone-and-cursor artwork, without its icon background.
@MainActor
enum MenuBarIcon {
    static func statusImage(bundle: Bundle = .main) -> NSImage? {
        let image = image(color: .black, bundle: bundle)
        image?.isTemplate = true // macOS supplies a neutral color for the menu bar appearance.
        return image
    }

    /// A green dot means ready; a red dot indicates setup is needed.
    final class ReadinessIndicator: NSView {
        var state: State = .missingRequirements {
            didSet { needsDisplay = true }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            state.color.setFill()
            circle.fill()
        }
    }

    enum State: Equatable {
        case ready, missingRequirements

        static func permissions(inputMonitoring: Bool, accessibility: Bool, microphone: Bool, apiKey: Bool) -> State {
            inputMonitoring && accessibility && microphone && apiKey ? .ready : .missingRequirements
        }

        var color: NSColor {
            switch self {
            case .ready: return NSColor(srgbRed: 53 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1)
            case .missingRequirements: return NSColor(srgbRed: 1, green: 92 / 255, blue: 96 / 255, alpha: 1)
            }
        }

    }

    static func image(color: NSColor, height: CGFloat = 18, bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.url(forResource: "MenuBarSymbols", withExtension: "png"),
              let source = NSImage(contentsOf: url) else { return nil }
        // Crop the existing artwork's generous app-icon padding at menu bar size.
        let size = NSSize(width: height * 750 / 550, height: height)
        guard let artwork = source.cgImage(forProposedRect: nil, context: nil, hints: nil)?
            .cropping(to: CGRect(x: 137, y: 237, width: 750, height: 550)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(ceil(size.width * 2)), height: Int(height * 2),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        context.interpolationQuality = .high
        context.draw(artwork, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: 1)
        context.fill(rect)
        guard let pixels = context.makeImage() else { return nil }
        let image = NSImage(cgImage: pixels, size: size)
        image.isTemplate = false // The status-image factory opts into template rendering.
        image.accessibilityDescription = "TalkToPrompt microphone and text cursor"
        return image
    }
}
