import AppKit
import QuartzCore

/// One circle responds to the latest volume; captions remain stationary above it.
@MainActor
final class AudioVisualizationView: NSView {
    static let centralOpacity: Float = 0.45
    static let intensityGain: CGFloat = 0.8
    let geometryLayer = CALayer()
    let circle = CAShapeLayer()
    private(set) var isListening = false
    private(set) var isProcessing = false
    private(set) var centralRadius: CGFloat = 180
    private(set) var intensity: Float = 0
    private(set) var isWarning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(geometryLayer)
        geometryLayer.setValue(0, forKeyPath: "transform.scale")
        circle.fillColor = NSColor.white.cgColor
        circle.opacity = Self.centralOpacity
        geometryLayer.addSublayer(circle)
        isHidden = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        geometryLayer.bounds = bounds
        geometryLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let availableRadius = max(1, min(bounds.width, bounds.height) / 2 - 20)
        centralRadius = min(180, availableRadius / (1 + Self.intensityGain))
        circle.frame = bounds
        setRadius(animated: false)
        CATransaction.commit()
    }

    func setState(listening: Bool, processing: Bool, visible: Bool) {
        let appearing = isHidden && visible
        isHidden = !visible
        if isListening != listening {
            isListening = listening
            intensity = 0
            setRadius(animated: true)
        }
        if isProcessing != processing {
            isProcessing = processing
            let opacity = circle.presentation()?.opacity ?? circle.opacity
            circle.removeAnimation(forKey: "processingPulse")
            circle.opacity = Self.centralOpacity
            if processing {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = opacity
                pulse.toValue = 0.15
                pulse.duration = 0.85
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                circle.add(pulse, forKey: "processingPulse")
            }
        }
        if !visible {
            intensity = 0
            circle.removeAllAnimations()
            setRadius(animated: false)
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
        setRadius(animated: animated)
    }

    private func setRadius(animated: Bool) {
        let radius = centralRadius * (1 + CGFloat(intensity) * Self.intensityGain)
        let path = CGPath(ellipseIn: CGRect(x: bounds.midX - radius, y: bounds.midY - radius,
                                           width: radius * 2, height: radius * 2), transform: nil)
        let current = circle.presentation()?.path ?? circle.path ?? path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.path = path
        circle.removeAnimation(forKey: "path")
        if animated {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = current
            animation.toValue = path
            animation.duration = 0.06
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            circle.add(animation, forKey: "path")
        }
        CATransaction.commit()
    }

    /// Scaling only the geometry leaves the caption stationary. Audio updates
    /// can continue changing paths without interrupting the radius transition.
    func animateVisibility(visible: Bool, duration: TimeInterval, fromZero: Bool = false) {
        let previous = geometryLayer.animation(forKey: "radiusScale") as? CABasicAnimation
        let current = fromZero ? 0 :
            (geometryLayer.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue
            ?? (previous?.fromValue as? NSNumber)?.doubleValue
            ?? (geometryLayer.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? 0
        let target = visible ? 1.0 : 0.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        geometryLayer.setValue(target, forKeyPath: "transform.scale")
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        geometryLayer.add(animation, forKey: "radiusScale")
        CATransaction.commit()
    }

    func resetVisibility() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        geometryLayer.removeAnimation(forKey: "radiusScale")
        geometryLayer.setValue(0, forKeyPath: "transform.scale")
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
