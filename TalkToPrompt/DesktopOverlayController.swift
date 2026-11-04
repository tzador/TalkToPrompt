import AppKit
import QuartzCore

/// One decorative, non-activating panel per screen, including menu bar and Dock.
@MainActor
final class DesktopOverlayController {
    static let fadeDuration: TimeInterval = 0.222
    private static let fadeAnimationKey = "overlayFade"
    private let screenFrames: () -> [NSRect]
    private var screenObserver: NSObjectProtocol?
    private(set) var panels: [OverlayPanel] = []
    private(set) var isVisible = false

    init(screenFrames: @escaping () -> [NSRect] = { NSScreen.screens.map(\.frame) }) {
        self.screenFrames = screenFrames
    }

    func start() {
        guard screenObserver == nil else { return }
        refreshScreens()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.screenObserver != nil else { return }
                self.refreshScreens()
            }
        }
    }

    func show() {
        start()
        guard !isVisible else { return }
        isVisible = true
        for panel in panels { fade(panel, to: 1) }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        for panel in panels { fade(panel, to: 0) }
    }

    func hideImmediately() {
        isVisible = false
        for panel in panels { hideImmediately(panel) }
    }

    func stop() {
        hideImmediately()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for panel in panels { panel.close() }
        panels.removeAll()
    }

    func refreshScreens() {
        let frames = screenFrames()
        guard panels.map(\.frame) != frames else { return }
        for panel in panels {
            hideImmediately(panel)
            panel.close()
        }
        panels = frames.map { frame in
            OverlayPanel(frame: frame)
        }
        if isVisible {
            for panel in panels { fade(panel, to: 1) }
        }
    }

    private func fade(_ panel: OverlayPanel, to opacity: Float) {
        guard let layer = panel.contentView?.layer else { return }
        let previousAnimation = layer.animation(forKey: Self.fadeAnimationKey) as? CABasicAnimation
        let currentOpacity = layer.presentation()?.opacity
            ?? (previousAnimation?.fromValue as? NSNumber)?.floatValue
            ?? layer.opacity
        let transitionID = UUID()
        panel.transitionID = transitionID
        layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.setCompletionBlock { [weak panel] in
            Task { @MainActor [weak panel] in
                guard let panel, panel.transitionID == transitionID, opacity == 0 else { return }
                panel.orderOut(nil)
            }
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = currentOpacity
        animation.toValue = opacity
        animation.duration = Self.fadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: Self.fadeAnimationKey)
        CATransaction.commit()
        if opacity > 0 { panel.orderFrontRegardless() }
    }

    private func hideImmediately(_ panel: OverlayPanel) {
        panel.transitionID = UUID()
        panel.orderOut(nil)
        guard let layer = panel.contentView?.layer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
    }

    final class OverlayPanel: NSPanel {
        var transitionID = UUID()
        init(frame: NSRect) {
            super.init(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            title = "TalkToPrompt Overlay"
            setFrame(frame, display: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            ignoresMouseEvents = true
            hidesOnDeactivate = false
            isReleasedWhenClosed = false
            isExcludedFromWindowsMenu = true
            animationBehavior = .none
            level = .screenSaver
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            contentView = OverlayContentView(frame: NSRect(origin: .zero, size: frame.size))
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    final class OverlayContentView: NSView {
        let backdrop = NSVisualEffectView()
        let whiteTint = NSView()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.opacity = 0

            // AppKit supplies live, system-managed backdrop blur without screen
            // capture. The container fade animates its visible strength; the
            // public API does not expose a configurable blur radius.
            backdrop.frame = bounds
            backdrop.autoresizingMask = [.width, .height]
            backdrop.material = .fullScreenUI
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            backdrop.appearance = NSAppearance(named: .aqua)
            addSubview(backdrop)

            whiteTint.frame = bounds
            whiteTint.autoresizingMask = [.width, .height]
            whiteTint.wantsLayer = true
            whiteTint.layer?.backgroundColor = NSColor.white.cgColor
            whiteTint.layer?.opacity = 0.8
            addSubview(whiteTint)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
