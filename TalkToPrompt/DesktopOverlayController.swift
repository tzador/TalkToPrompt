import AppKit
import QuartzCore

/// One decorative, non-activating panel per screen, including menu bar and Dock.
@MainActor
final class DesktopOverlayController: VoiceSessionOverlay {
    static let fadeDuration: TimeInterval = 0.222
    private static let fadeAnimationKey = "overlayFade"
    private let screenFrames: () -> [NSRect]
    private var screenObserver: NSObjectProtocol?
    private var hideTask: Task<Void, Never>?
    private var dotsTimer: Timer?
    private var dotCount = 0
    private var animatedStatus: String?
    private(set) var panels: [OverlayPanel] = []
    private(set) var isVisible = false
    private(set) var isListening = false
    private(set) var message: String?

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
        hideTask?.cancel()
        hideTask = nil
        start()
        guard !isVisible else { return }
        isVisible = true
        for panel in panels { fade(panel, to: 1) }
    }

    func hide(completion: (() -> Void)? = nil) {
        guard isVisible || panels.contains(where: \.isVisible) else { completion?(); return }
        isVisible = false
        hideTask?.cancel()
        for panel in panels { fade(panel, to: 0) }
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(Self.fadeDuration)) }
            catch { return }
            guard let self, !Task.isCancelled, !self.isVisible else { return }
            for panel in self.panels { self.hideImmediately(panel) }
            self.setMessage(nil)
            self.hideTask = nil
            completion?()
        }
    }

    func hideImmediately() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = false
        setListening(false)
        for panel in panels { hideImmediately(panel) }
    }

    func setListening(_ listening: Bool) {
        setMessage(listening ? "Listening..." : nil)
    }

    func setMessage(_ message: String?) {
        self.message = message
        isListening = message?.hasPrefix("Listening...") == true
        let status = message.map { message in
            guard let separator = message.range(of: "... ") else { return message }
            return String(message[..<separator.lowerBound]) + "..."
        }
        let animatedStatus = ["Listening...", "Transcribing...", "Translating..."].contains(status ?? "") ? status : nil
        if self.animatedStatus != animatedStatus {
            dotsTimer?.invalidate()
            dotsTimer = nil
            dotCount = 0
            self.animatedStatus = animatedStatus
            if animatedStatus != nil {
                let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.dotCount = (self.dotCount + 1) % 4
                        for panel in self.panels {
                            (panel.contentView as? OverlayContentView)?.setDotCount(self.dotCount)
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                dotsTimer = timer
            }
        }
        for panel in panels {
            guard let view = panel.contentView as? OverlayContentView else { continue }
            view.setMessage(message)
            view.setDotCount(dotCount)
        }
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
            let panel = OverlayPanel(frame: frame)
            let view = panel.contentView as? OverlayContentView
            view?.setMessage(message)
            view?.setDotCount(dotCount)
            return panel
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
        let backgroundTint = NSView()
        let statusLabel = NSTextField(labelWithString: "")
        let counterLabel = NSTextField(labelWithString: "")
        private var animatesDots = false
        private var dotCount = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.opacity = 0

            backgroundTint.frame = bounds
            backgroundTint.autoresizingMask = [.width, .height]
            backgroundTint.wantsLayer = true
            backgroundTint.layer?.backgroundColor = NSColor.black.cgColor
            backgroundTint.layer?.opacity = 0.25
            addSubview(backgroundTint)

            statusLabel.font = .systemFont(ofSize: 64, weight: .bold)
            statusLabel.textColor = .white
            statusLabel.alignment = .center
            statusLabel.maximumNumberOfLines = 0
            statusLabel.lineBreakMode = .byWordWrapping
            statusLabel.isHidden = true
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(statusLabel)
            counterLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .regular)
            counterLabel.textColor = NSColor.white.withAlphaComponent(0.7)
            counterLabel.alignment = .center
            counterLabel.isHidden = true
            counterLabel.translatesAutoresizingMaskIntoConstraints = false
            counterLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(counterLabel)
            NSLayoutConstraint.activate([
                statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                counterLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                counterLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
                counterLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                counterLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
            ])
        }

        func setMessage(_ message: String?) {
            if let message, let separator = message.range(of: "... ") {
                statusLabel.stringValue = String(message[..<separator.lowerBound]) + "..."
                counterLabel.stringValue = String(message[separator.upperBound...])
            } else {
                statusLabel.stringValue = message ?? ""
                counterLabel.stringValue = ""
            }
            statusLabel.isHidden = message == nil
            counterLabel.isHidden = counterLabel.stringValue.isEmpty
            animatesDots = ["Listening...", "Transcribing...", "Translating..."].contains(statusLabel.stringValue)
            setDotCount(dotCount)
        }

        func setDotCount(_ count: Int) {
            dotCount = count
            guard animatesDots else { return }
            // Keep all three glyphs in the layout and only change their ink.
            // This preserves the word's position throughout the entire cycle.
            let text = statusLabel.stringValue
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: statusLabel.font ?? NSFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ])
            attributed.addAttribute(.foregroundColor, value: NSColor.clear,
                                    range: NSRange(location: (text as NSString).length - 3 + count,
                                                   length: 3 - count))
            statusLabel.attributedStringValue = attributed
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
