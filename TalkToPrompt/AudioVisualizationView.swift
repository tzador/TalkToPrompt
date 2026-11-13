import AppKit
import QuartzCore

/// Circle and dimmer share radius animations so their translucent fills never overlap.
@MainActor
final class AudioVisualizationView: NSView {
    static let centralOpacity: Float = 0.9
    static let volumeAnimationDuration: TimeInterval = 0.12
    static let dimmingOpacity: CGFloat = 0.40
    static let intensityGain: CGFloat = 0.8
    static let processingPeriod: TimeInterval = 2.4
    static let processingAmplitude: CGFloat = 0.10
    let dimmer = CAShapeLayer()
    let geometryLayer = CALayer()
    let circle = CAShapeLayer()
    private(set) var isListening = false
    private(set) var isProcessing = false
    private(set) var centralRadius: CGFloat = 180
    private(set) var intensity: Float = 0
    private(set) var isWarning = false
    private var visibility: CGFloat = 0
    private var visibilityTransitionEnds: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dimmer.fillRule = .evenOdd
        dimmer.fillColor = NSColor.black.withAlphaComponent(Self.dimmingOpacity).cgColor
        layer?.addSublayer(dimmer)
        layer?.addSublayer(geometryLayer)
        circle.fillColor = NSColor.white.cgColor
        circle.opacity = Self.centralOpacity
        geometryLayer.addSublayer(circle)
        isHidden = true
    }

    override func layout() {
        super.layout()
        guard geometryLayer.bounds != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimmer.frame = bounds
        geometryLayer.bounds = bounds
        geometryLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let availableRadius = max(1, min(bounds.width, bounds.height) / 2 - 20)
        centralRadius = min(180, availableRadius / (1 + Self.intensityGain))
        circle.frame = bounds
        transitionRadius(to: currentRadius, duration: 0)
        if isProcessing && visibility > 0 { startProcessingPulse() }
        CATransaction.commit()
    }

    func setState(listening: Bool, processing: Bool, visible: Bool) {
        let appearing = isHidden && visible
        let changed = isListening != listening || isProcessing != processing
        isHidden = !visible
        isListening = listening
        isProcessing = processing
        if changed {
            intensity = 0
            if processing && !appearing {
                transitionRadius(to: currentRadius, duration: DesktopOverlayController.fadeDuration)
                startProcessingPulse(after: DesktopOverlayController.fadeDuration)
            } else if !appearing {
                transitionRadius(to: currentRadius, duration: 0.06)
            }
        }
        if !visible {
            intensity = 0
            resetVisibility()
        } else if appearing {
            layoutSubtreeIfNeeded()
            animateVisibility(visible: true, duration: DesktopOverlayController.fadeDuration, fromZero: true)
        }
    }

    func setWarning(_ warning: Bool) {
        guard isWarning != warning else { return }
        isWarning = warning
        let color = (warning ? NSColor.systemRed : NSColor.white).cgColor
        let animation = CABasicAnimation(keyPath: "fillColor")
        animation.fromValue = circle.presentation()?.fillColor ?? circle.fillColor
        animation.toValue = color
        animation.duration = DesktopOverlayController.fadeDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.fillColor = color
        circle.add(animation, forKey: "warningColor")
        CATransaction.commit()
    }

    func updateIntensity(_ value: Float, animated: Bool = true) {
        guard isListening else { return }
        intensity = value.isFinite ? min(1, max(0, value)) : 0
        // Let the entrance complete without live audio replacing its animation.
        guard !animated || CACurrentMediaTime() >= visibilityTransitionEnds else { return }
        transitionRadius(to: currentRadius, duration: animated ? Self.volumeAnimationDuration : 0)
    }

    private var currentRadius: CGFloat {
        centralRadius * (1 + CGFloat(intensity) * Self.intensityGain) * visibility
    }

    private func paths(radius: CGFloat) -> (circle: CGPath, dimmer: CGPath) {
        let circle = CGPath(ellipseIn: CGRect(x: bounds.midX - radius, y: bounds.midY - radius,
                                             width: radius * 2, height: radius * 2), transform: nil)
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(circle)
        return (circle, outside)
    }

    private func transitionRadius(to radius: CGFloat, duration: TimeInterval, key: String = "path") {
        let target = paths(radius: radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (shape, path) in [(circle, target.circle), (dimmer, target.dimmer)] {
            let previous = shape.animation(forKey: "radiusScale") as? CABasicAnimation
            let current = shape.presentation()?.path ?? (previous?.fromValue as! CGPath?) ?? shape.path ?? path
            shape.removeAnimation(forKey: "path")
            shape.removeAnimation(forKey: "radiusScale")
            shape.removeAnimation(forKey: "processingPulse")
            shape.path = path
            if duration > 0 {
                let animation = CABasicAnimation(keyPath: "path")
                animation.fromValue = current
                animation.toValue = path
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: key == "path" ? .easeOut : .easeInEaseOut)
                shape.add(animation, forKey: key)
            }
        }
        CATransaction.commit()
    }

    private func startProcessingPulse(after delay: TimeInterval = 0) {
        let samples = 120
        let frames = (0...samples).map { index in
            paths(radius: centralRadius * (1 + Self.processingAmplitude * CGFloat(sin(2 * .pi * Double(index) / Double(samples)))))
        }
        let start = CACurrentMediaTime() + delay
        for (shape, values) in [(circle, frames.map(\.circle)), (dimmer, frames.map(\.dimmer))] {
            let pulse = CAKeyframeAnimation(keyPath: "path")
            pulse.values = values
            pulse.duration = Self.processingPeriod
            pulse.beginTime = start
            pulse.repeatCount = .infinity
            pulse.calculationMode = .linear
            shape.add(pulse, forKey: "processingPulse")
        }
    }

    func animateVisibility(visible: Bool, duration: TimeInterval, fromZero: Bool = false) {
        if fromZero { resetVisibility() }
        visibility = visible ? 1 : 0
        visibilityTransitionEnds = CACurrentMediaTime() + duration
        transitionRadius(to: currentRadius, duration: duration, key: "radiusScale")
        let previousFade = dimmer.animation(forKey: "dimmingFade") as? CABasicAnimation
        let currentOpacity = dimmer.presentation()?.opacity
            ?? (previousFade?.fromValue as? NSNumber)?.floatValue ?? dimmer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimmer.opacity = visible ? 1 : 0
        dimmer.removeAnimation(forKey: "dimmingFade")
        if duration > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromZero ? 0 : currentOpacity
            fade.toValue = dimmer.opacity
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dimmer.add(fade, forKey: "dimmingFade")
        }
        CATransaction.commit()
        if visible && isProcessing { startProcessingPulse(after: duration) }
    }

    func resetVisibility() {
        visibility = 0
        visibilityTransitionEnds = 0
        transitionRadius(to: 0, duration: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimmer.removeAnimation(forKey: "dimmingFade")
        dimmer.opacity = 0
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
