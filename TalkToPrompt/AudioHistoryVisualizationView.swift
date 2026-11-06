import AppKit
import QuartzCore

@MainActor
final class AudioHistoryVisualizationView: NSView {
    static let historyCount = 32
    static let centralOpacity: Float = 0.45
    static let intensityGain: CGFloat = 2
    let geometryLayer = CALayer()
    let circle = CAShapeLayer()
    /// Inside to outside: newest 10 ms slice first, oldest last.
    let rings = (0..<AudioHistoryVisualizationView.historyCount).map { _ in CAShapeLayer() }
    private(set) var isListening = false
    private(set) var isProcessing = false
    private var history = [Float](repeating: 0, count: AudioHistoryVisualizationView.historyCount)
    private(set) var centralRadius: CGFloat = 180
    private(set) var radiusStep: CGFloat = 17
    private(set) var maximumDisplacement: CGFloat = 7.65
    static var collapseDuration: TimeInterval { DesktopOverlayController.fadeDuration }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(geometryLayer)
        geometryLayer.setValue(0, forKeyPath: "transform.scale")
        for (index, ring) in rings.enumerated().reversed() {
            // Fade the filled bands to zero at the last filled boundary;
            // the alternating gaps stay fully transparent throughout.
            let fade = max(0, 1 - CGFloat(index) / CGFloat(Self.historyCount - 2))
            let opacity = index.isMultiple(of: 2) ? CGFloat(Self.centralOpacity) * fade : 0
            ring.fillColor = NSColor.white.withAlphaComponent(opacity).cgColor
            ring.fillRule = .evenOdd
            ring.strokeColor = nil
            ring.opacity = 0
            geometryLayer.addSublayer(ring)
        }
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
        let availableRadius = max(1, min(520, min(bounds.width, bounds.height) / 2 - 20))
        centralRadius = min(180, availableRadius * 0.54)
        radiusStep = (availableRadius - centralRadius) / CGFloat(Self.historyCount + 1)
        // Keep audio sensitivity independent of the number and spread of rings.
        maximumDisplacement = centralRadius * 0.043
        circle.frame = bounds
        circle.path = path(radius: centralRadius)
        for ring in rings {
            ring.frame = bounds
            ring.removeAnimation(forKey: "path")
            ring.path = bandPath(innerRadius: centralRadius, outerRadius: centralRadius)
        }
        CATransaction.commit()
        if isListening { updateHistory(history, animated: false) }
    }

    func setState(listening: Bool, processing: Bool, visible: Bool) {
        let appearing = isHidden && visible
        isHidden = !visible
        if isListening != listening {
            isListening = listening
            if listening {
                history = Array(repeating: 0, count: Self.historyCount)
                updateHistory(history)
            } else {
                for ring in rings {
                    animatePath(ring, to: bandPath(innerRadius: centralRadius, outerRadius: centralRadius),
                                duration: Self.collapseDuration)
                    animateOpacity(ring, to: 0, duration: Self.collapseDuration)
                }
            }
        }
        if isProcessing != processing {
            isProcessing = processing
            let opacity = circle.presentation()?.opacity ?? circle.opacity
            circle.removeAnimation(forKey: "processingPulse")
            circle.removeAnimation(forKey: "opacity")
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
            history = Array(repeating: 0, count: Self.historyCount)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for ring in rings {
                ring.removeAllAnimations()
                ring.path = bandPath(innerRadius: centralRadius, outerRadius: centralRadius)
                ring.opacity = 0
            }
            circle.removeAllAnimations()
            CATransaction.commit()
            resetVisibility()
        } else if appearing {
            layoutSubtreeIfNeeded()
            animateVisibility(visible: true, duration: DesktopOverlayController.fadeDuration, fromZero: true)
        }
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

    func updateHistory(_ values: [Float], animated: Bool = true) {
        guard isListening, values.count == Self.historyCount else { return }
        history = values.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        // Stronger movement can exceed the spacing. Keep each outer boundary
        // beyond its neighbor so the alternating bands never invert or overlap.
        let duration: TimeInterval = animated ? AudioIntensityAnalyzer.interval : 0
        var innerRadius = centralRadius
        for (index, ring) in rings.enumerated() {
            let displacedRadius = centralRadius + CGFloat(index + 1) * radiusStep
                + CGFloat(history[index]) * maximumDisplacement * Self.intensityGain
            let radius = max(displacedRadius, innerRadius + radiusStep * 0.15)
            animatePath(ring, to: bandPath(innerRadius: innerRadius, outerRadius: radius), duration: duration)
            if ring.opacity != 1 { animateOpacity(ring, to: 1, duration: duration) }
            innerRadius = radius
        }
    }

    private func bandPath(innerRadius: CGFloat, outerRadius: CGFloat) -> CGPath {
        let band = CGMutablePath()
        band.addPath(path(radius: outerRadius))
        band.addPath(path(radius: innerRadius))
        return band
    }

    private func path(radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: bounds.midX - radius, y: bounds.midY - radius,
                                width: 2 * radius, height: 2 * radius), transform: nil)
    }

    private func animatePath(_ shape: CAShapeLayer, to path: CGPath, duration: TimeInterval) {
        let current = shape.presentation()?.path ?? shape.path
            ?? bandPath(innerRadius: centralRadius, outerRadius: centralRadius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        shape.removeAnimation(forKey: "path")
        if duration > 0 {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = current
            animation.toValue = path
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(animation, forKey: "path")
        }
        CATransaction.commit()
    }

    private func animateOpacity(_ shape: CAShapeLayer, to opacity: Float, duration: TimeInterval) {
        let current = shape.presentation()?.opacity ?? shape.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.opacity = opacity
        shape.removeAnimation(forKey: "opacity")
        if duration > 0 {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = current
            animation.toValue = opacity
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(animation, forKey: "opacity")
        }
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
