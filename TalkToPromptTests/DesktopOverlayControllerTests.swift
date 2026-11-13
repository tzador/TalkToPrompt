import AppKit
import QuartzCore
import XCTest
@testable import TalkToPrompt

final class DesktopOverlayControllerTests: XCTestCase {
    @MainActor
    func testTimerUsesMinutesAndSecondsAboveMonospacedListeningLabel() throws {
        let view = DesktopOverlayController.OverlayContentView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        for (seconds, expected) in [(0, "00:00"), (17, "00:17"), (59, "00:59"), (60, "01:00"), (65, "01:05"), (359, "05:59")] {
            view.setMessage("Listening... \(seconds) seconds")
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.counterLabel.stringValue, expected)
            XCTAssertGreaterThan(view.counterLabel.frame.minY, view.statusLabel.frame.maxY)
            for label in [view.statusLabel, view.counterLabel] {
                XCTAssertTrue(try XCTUnwrap(label.font).isFixedPitch)
            }
        }
        view.setMessage("Transcribing...")
        XCTAssertTrue(view.counterLabel.isHidden)
        XCTAssertEqual(view.visualization.circle.opacity, 0.9)
    }

    @MainActor
    func testVolumeTransitionsAreSmoothedForBothCircleAndDimmer() throws {
        let view = AudioVisualizationView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        view.setState(listening: true, processing: false, visible: true)
        view.animateVisibility(visible: true, duration: 0)
        for volume: Float in [0.8, 0.1] {
            view.updateIntensity(volume)
            let animation = try XCTUnwrap(view.circle.animation(forKey: "path") as? CABasicAnimation)
            XCTAssertEqual(animation.duration, 0.12)
            XCTAssertEqual(view.dimmer.animation(forKey: "path")?.duration, animation.duration)
        }
    }

    @MainActor
    func testDimmerExcludesCircleDuringVolumePulseAndCollapseAnimations() throws {
        let view = AudioVisualizationView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        view.setState(listening: true, processing: false, visible: true)
        view.animateVisibility(visible: true, duration: 0)
        view.updateIntensity(0.7, animated: false)
        let center = CGPoint(x: 400, y: 400)
        let corner = CGPoint(x: 10, y: 10)
        XCTAssertTrue(try XCTUnwrap(view.circle.path).contains(center))
        XCTAssertFalse(try XCTUnwrap(view.dimmer.path).contains(center, using: .evenOdd))
        XCTAssertTrue(try XCTUnwrap(view.dimmer.path).contains(corner, using: .evenOdd))
        view.setState(listening: false, processing: true, visible: true)
        let circlePulse = try XCTUnwrap(view.circle.animation(forKey: "processingPulse") as? CAKeyframeAnimation)
        let dimmerPulse = try XCTUnwrap(view.dimmer.animation(forKey: "processingPulse") as? CAKeyframeAnimation)
        XCTAssertEqual(circlePulse.keyPath, "path")
        XCTAssertEqual(circlePulse.duration, AudioVisualizationView.processingPeriod)
        XCTAssertEqual(circlePulse.beginTime, dimmerPulse.beginTime)
        XCTAssertEqual(circlePulse.repeatCount, .infinity)
        XCTAssertNil(view.circle.animation(forKey: "opacity"))
        let circles = try XCTUnwrap(circlePulse.values as? [CGPath])
        let shades = try XCTUnwrap(dimmerPulse.values as? [CGPath])
        XCTAssertEqual(circles.count, 121)
        XCTAssertEqual(circles.count, shades.count)
        for index in circles.indices {
            let radius = view.centralRadius * (1 + AudioVisualizationView.processingAmplitude * CGFloat(sin(2 * .pi * Double(index) / 120)))
            XCTAssertEqual(circles[index].boundingBox.width / 2, radius, accuracy: 0.001)
            XCTAssertFalse(shades[index].contains(center, using: .evenOdd))
            XCTAssertTrue(shades[index].contains(CGPoint(x: 400 + radius + 1, y: 400), using: .evenOdd))
            XCTAssertFalse(shades[index].contains(CGPoint(x: 400 + radius - 1, y: 400), using: .evenOdd))
        }
        view.animateVisibility(visible: false, duration: DesktopOverlayController.fadeDuration)
        XCTAssertNil(view.circle.animation(forKey: "processingPulse"))
        XCTAssertNil(view.dimmer.animation(forKey: "processingPulse"))
        XCTAssertEqual(view.circle.path?.boundingBox.width, 0)
        XCTAssertTrue(try XCTUnwrap(view.dimmer.path).contains(center, using: .evenOdd))
        XCTAssertEqual(view.circle.animation(forKey: "radiusScale")?.duration,
                       view.dimmer.animation(forKey: "radiusScale")?.duration)
    }

    @MainActor
    func testSingleCircleRespondsToLatestVolumeAndCollapsesWithFade() throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 800, height: 800)] })
        defer { overlay.stop() }
        overlay.setListening(true)
        overlay.show()
        let view = try XCTUnwrap(overlay.panels.first?.contentView as? DesktopOverlayController.OverlayContentView)
        view.layoutSubtreeIfNeeded()
        let visualization = view.visualization
        XCTAssertEqual(visualization.geometryLayer.sublayers?.count, 1)
        XCTAssertTrue(visualization.geometryLayer.sublayers?.first === visualization.circle)
        XCTAssertEqual(visualization.circle.path?.boundingBox.width, visualization.centralRadius * 2)
        XCTAssertEqual(visualization.circle.animation(forKey: "radiusScale")?.duration, DesktopOverlayController.fadeDuration)
        let dimming = try XCTUnwrap(visualization.dimmer.animation(forKey: "dimmingFade") as? CABasicAnimation)
        XCTAssertEqual(dimming.duration, DesktopOverlayController.fadeDuration)
        XCTAssertEqual(dimming.fromValue as? Float, 0)
        XCTAssertEqual(dimming.toValue as? Float, 1)
        visualization.animateVisibility(visible: true, duration: 0)
        overlay.appendIntensities([1, 0.2, 0.5])
        XCTAssertEqual(overlay.currentIntensity, 0.5)
        let bounds = try XCTUnwrap(visualization.circle.path).boundingBox
        XCTAssertEqual(bounds.width / 2, visualization.centralRadius * (1 + 0.5 * AudioVisualizationView.intensityGain), accuracy: 0.001)
        XCTAssertEqual(bounds.midX, view.bounds.midX, accuracy: 0.001)
        XCTAssertEqual(bounds.midY, view.bounds.midY, accuracy: 0.001)
        overlay.appendIntensities([0])
        XCTAssertEqual(visualization.circle.path?.boundingBox.width, visualization.centralRadius * 2)
        overlay.setMessage("Transcribing...")
        overlay.appendIntensities([1])
        XCTAssertEqual(overlay.currentIntensity, 0)
        XCTAssertEqual(visualization.circle.path?.boundingBox.width, visualization.centralRadius * 2)
        XCTAssertNotNil(visualization.circle.animation(forKey: "processingPulse"))
        overlay.hide()
        let exit = try XCTUnwrap(visualization.circle.animation(forKey: "radiusScale") as? CABasicAnimation)
        XCTAssertEqual(exit.duration, DesktopOverlayController.fadeDuration)
        XCTAssertEqual(visualization.circle.path?.boundingBox.width, 0)
        XCTAssertEqual(visualization.dimmer.animation(forKey: "radiusScale")?.duration, exit.duration)
        overlay.hideImmediately()
        XCTAssertNil(visualization.circle.animation(forKey: "radiusScale"))
        XCTAssertNil(visualization.circle.animation(forKey: "processingPulse"))
    }

    @MainActor
    func testWarningAndVolumeAreInheritedWithoutDisplayingBufferReport() throws {
        var frames = [NSRect(x: 0, y: 0, width: 800, height: 800)]
        let overlay = DesktopOverlayController(screenFrames: { frames })
        defer { overlay.stop() }
        overlay.show()
        overlay.setMessage("Listening... 625 seconds")
        overlay.setBufferUsage(.init(byteCount: 19_999_999))
        let original = try XCTUnwrap(overlay.panels.first?.contentView as? DesktopOverlayController.OverlayContentView)
        XCTAssertFalse(original.visualization.isWarning)
        overlay.setBufferUsage(.init(byteCount: 20_000_000))
        overlay.appendIntensities([0.7])
        frames.append(NSRect(x: -800, y: 0, width: 800, height: 800))
        overlay.refreshScreens()
        for panel in overlay.panels {
            let view = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(view.visualization.isWarning)
            XCTAssertEqual(view.visualization.circle.fillColor, NSColor.systemRed.cgColor)
            XCTAssertEqual(view.visualization.intensity, 0.7)
            XCTAssertEqual(view.counterLabel.stringValue, "10:25")
            let labels = view.captionSurface.subviews.compactMap { $0 as? NSTextField }
            XCTAssertEqual(labels.count, 2)
            XCTAssertFalse(labels.contains { $0.stringValue.contains("%") || $0.stringValue.contains("remaining") })
            XCTAssertEqual(view.visualization.circle.opacity, 0.9)
            XCTAssertGreaterThan(view.counterLabel.frame.minY, view.statusLabel.frame.maxY)
        }
        overlay.setMessage("Transcribing...")
        for panel in overlay.panels {
            let view = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
            XCTAssertTrue(view.counterLabel.isHidden)
            XCTAssertTrue(view.visualization.isWarning)
        }
        overlay.setBufferUsage(.empty)
        overlay.setMessage("Listening... 0 seconds")
        for panel in overlay.panels {
            let view = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
            XCTAssertFalse(view.visualization.isWarning)
            XCTAssertEqual(view.visualization.circle.fillColor, NSColor.white.cgColor)
            XCTAssertEqual(view.counterLabel.stringValue, "00:00")
        }
    }

    @MainActor
    func testVolumeIsClampedAndNewScreensUseLatestValue() throws {
        var frames = [NSRect(x: 0, y: 0, width: 800, height: 800)]
        let overlay = DesktopOverlayController(screenFrames: { frames })
        defer { overlay.stop() }
        overlay.show()
        overlay.setListening(true)
        for (input, expected): (Float, Float) in [(-1, 0), (2, 1), (.nan, 0), (.infinity, 0), (0.4, 0.4)] {
            overlay.appendIntensities([input])
            XCTAssertEqual(overlay.currentIntensity, expected)
        }
        frames.append(NSRect(x: -800, y: 0, width: 800, height: 800))
        overlay.refreshScreens()
        for panel in overlay.panels {
            let view = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
            XCTAssertEqual(view.visualization.intensity, 0.4)
        }
    }

    @MainActor
    func testStatusLetterCyclesWithoutDotsResettingOrMovingText() async throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 800, height: 600)] })
        defer { overlay.stop() }
        overlay.start()
        for (message, update, word) in [("Listening... 0 seconds", "Listening... 2 seconds", "Listening"),
                                        ("Transcribing...", "Transcribing...", "Transcribing")] {
            overlay.setMessage(message)
            let view = try XCTUnwrap(overlay.panels.first?.contentView as? DesktopOverlayController.OverlayContentView)
            view.layoutSubtreeIfNeeded()
            let initialFrame = view.statusLabel.frame
            XCTAssertEqual(view.statusLabel.stringValue, word)
            func color(at index: Int) -> NSColor? {
                view.statusLabel.attributedStringValue.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
            }
            XCTAssertEqual(color(at: 0), DesktopOverlayController.OverlayContentView.textColor)
            for _ in 0..<100 {
                if color(at: 1) == DesktopOverlayController.OverlayContentView.textColor { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(color(at: 1), DesktopOverlayController.OverlayContentView.textColor)
            overlay.setMessage(update)
            XCTAssertEqual(color(at: 1), DesktopOverlayController.OverlayContentView.textColor)
            for step in 0...word.count {
                view.setHighlightedLetter(step)
                for index in 0..<word.count {
                    XCTAssertEqual(color(at: index), index == step % word.count ? DesktopOverlayController.OverlayContentView.textColor : DesktopOverlayController.OverlayContentView.secondaryTextColor)
                }
            }
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.statusLabel.frame, initialFrame)
        }
    }

    @MainActor
    func testElapsedStatusMessagesAreUpdatedOnEveryScreen() throws {
        var frames = [NSRect(x: 0, y: 0, width: 1000, height: 700)]
        let overlay = DesktopOverlayController(screenFrames: { frames })
        defer { overlay.stop() }
        overlay.start()
        overlay.setMessage("Listening... 13 seconds")
        XCTAssertTrue(overlay.isListening)
        overlay.setMessage("Speaking... 4 seconds")
        XCTAssertFalse(overlay.isListening)
        frames.append(NSRect(x: -1000, y: 0, width: 1000, height: 700))
        overlay.refreshScreens()
        for panel in overlay.panels {
            let view = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
            XCTAssertEqual(view.statusLabel.stringValue, "Speaking...")
            XCTAssertEqual(view.counterLabel.stringValue, "00:04")
            XCTAssertFalse(view.counterLabel.isHidden)
            XCTAssertEqual(view.counterLabel.font?.pointSize, 20)
            XCTAssertEqual(view.counterLabel.textColor, DesktopOverlayController.OverlayContentView.secondaryTextColor)
            let font = try XCTUnwrap(view.counterLabel.font)
            XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(view.counterLabel.frame.minY, view.statusLabel.frame.maxY)
            XCTAssertFalse(view.statusLabel.isHidden)
        }
    }

    @MainActor
    func testHideCompletionRunsOnlyAfterPanelsAreHidden() async throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 160, height: 120)] })
        defer { overlay.stop() }
        overlay.show()
        var completions = 0
        overlay.hide { completions += 1 }
        XCTAssertEqual(completions, 0)
        for _ in 0..<100 {
            if completions > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(overlay.panels.allSatisfy { !$0.isVisible })
    }

    @MainActor
    func testListeningCaptionIsGrayMonospacedAndCenteredOnlyWhenRequested() throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 800, height: 600)] })
        defer { overlay.stop() }
        overlay.start()
        let view = try XCTUnwrap(overlay.panels.first?.contentView as? DesktopOverlayController.OverlayContentView)
        XCTAssertTrue(view.statusLabel.isHidden)
        overlay.setListening(true)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.statusLabel.stringValue, "Listening")
        XCTAssertEqual(view.statusLabel.font?.pointSize, 54)
        XCTAssertEqual(view.statusLabel.textColor, DesktopOverlayController.OverlayContentView.secondaryTextColor)
        XCTAssertFalse(view.statusLabel.isHidden)
        XCTAssertEqual(view.statusLabel.frame.midX, view.bounds.midX, accuracy: 1)
        XCTAssertEqual(view.statusLabel.frame.midY, view.bounds.midY, accuracy: 1)
        overlay.hideImmediately()
        XCTAssertTrue(view.statusLabel.isHidden)
        XCTAssertFalse(overlay.isListening)
    }

    @MainActor
    func testNewScreensInheritTheListeningCaption() {
        var frames = [NSRect(x: 0, y: 0, width: 800, height: 600)]
        let overlay = DesktopOverlayController(screenFrames: { frames })
        defer { overlay.stop() }
        overlay.start()
        overlay.setListening(true)
        frames.append(NSRect(x: -800, y: 0, width: 800, height: 600))
        overlay.refreshScreens()
        for panel in overlay.panels {
            let view = panel.contentView as? DesktopOverlayController.OverlayContentView
            XCTAssertEqual(view?.statusLabel.isHidden, false)
        }
    }

    @MainActor
    func testQueuedDisplayNotificationCannotRecreatePanelsAfterStop() async {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 160, height: 120)] })
        overlay.start()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        overlay.stop()
        await Task.yield()
        XCTAssertTrue(overlay.panels.isEmpty)
        XCTAssertFalse(overlay.isVisible)
    }

    @MainActor
    func testCreatesOneNonActivatingPanelForEachFullScreenFrame() {
        let frames = [
            NSRect(x: 0, y: 0, width: 320, height: 240),
            NSRect(x: -400, y: 120, width: 400, height: 300)
        ]
        let overlay = DesktopOverlayController(screenFrames: { frames })
        defer { overlay.stop() }
        overlay.start()
        XCTAssertEqual(overlay.panels.map(\.frame), frames)
        XCTAssertFalse(overlay.isVisible)
        for panel in overlay.panels {
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertFalse(panel.hidesOnDeactivate)
            XCTAssertFalse(panel.hasShadow)
            XCTAssertFalse(panel.isOpaque)
            XCTAssertEqual(panel.level, .screenSaver)
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertEqual(panel.contentView?.layer?.opacity, 0)
        }
    }

    @MainActor
    func testDisplayFramesAreNotConstrainedToTheMainScreen() {
        let frames = [
            NSRect(x: -1920, y: -400, width: 1920, height: 1080),
            NSRect(x: 0, y: 1080, width: 2560, height: 1440)
        ]
        let overlay = DesktopOverlayController(screenFrames: { frames })
        defer { overlay.stop() }
        overlay.show()
        XCTAssertEqual(overlay.panels.map(\.frame), frames)
        for (panel, frame) in zip(overlay.panels, frames) {
            XCTAssertEqual(panel.constrainFrameRect(frame, to: NSScreen.main), frame)
            XCTAssertEqual(panel.contentView?.bounds.size, frame.size)
        }
    }

    @MainActor
    func testSpaceChangesRestoreEveryVisibleOverlayWithoutTakingFocus() async {
        let frames = [NSRect(x: 0, y: 0, width: 160, height: 120),
                      NSRect(x: -200, y: 0, width: 200, height: 150)]
        let overlay = DesktopOverlayController(screenFrames: { frames })
        defer { overlay.stop() }
        overlay.setListening(true)
        overlay.show()
        let keyWindow = NSApp.keyWindow
        // Simulate panels needing to be reordered after the active Space changes.
        for panel in overlay.panels { panel.orderOut(nil) }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for _ in 0..<100 {
            if overlay.panels.allSatisfy(\.isVisible) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(overlay.panels.map(\.frame), frames)
        XCTAssertTrue(overlay.panels.allSatisfy(\.isVisible))
        XCTAssertTrue(overlay.isListening)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)

        overlay.hideImmediately()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await Task.yield()
        XCTAssertTrue(overlay.panels.allSatisfy { !$0.isVisible })
    }

    @MainActor
    func testShowRefreshesAllDisplaysWithoutWaitingForScreenNotification() {
        var frames = [NSRect(x: 0, y: 0, width: 160, height: 120)]
        let overlay = DesktopOverlayController(screenFrames: { frames })
        defer { overlay.stop() }
        overlay.start()
        overlay.setListening(true)
        frames.append(NSRect(x: -200, y: 0, width: 200, height: 150))
        overlay.show()
        XCTAssertEqual(overlay.panels.map(\.frame), frames)
        XCTAssertTrue(overlay.panels.allSatisfy(\.isVisible))
        for panel in overlay.panels {
            let view = panel.contentView as? DesktopOverlayController.OverlayContentView
            XCTAssertEqual(view?.statusLabel.stringValue, "Listening")
        }
    }

    @MainActor
    func testShowFadesBlackToFortyPercentWithoutBlurOver222Milliseconds() throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 160, height: 120)] })
        defer { overlay.stop() }
        let keyWindow = NSApp.keyWindow
        overlay.show()
        XCTAssertTrue(overlay.isVisible)
        let panel = try XCTUnwrap(overlay.panels.first)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        let layer = try XCTUnwrap(panel.contentView?.layer)
        XCTAssertEqual(layer.opacity, 1)
        let animation = try XCTUnwrap(layer.animationKeys()?.compactMap {
            layer.animation(forKey: $0) as? CABasicAnimation
        }.first(where: { $0.keyPath == "opacity" }))
        XCTAssertEqual(animation.duration, 0.222)
        XCTAssertEqual(animation.fromValue as? Float, 0)
        XCTAssertEqual(animation.toValue as? Float, 1)
        let content = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
        XCTAssertFalse(content.subviews.contains { $0 is NSVisualEffectView })
        XCTAssertEqual(content.visualization.dimmer.fillRule, .evenOdd)
        let color = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(content.visualization.dimmer.fillColor))?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 0)
        XCTAssertEqual(color.greenComponent, 0)
        XCTAssertEqual(color.blueComponent, 0)
        XCTAssertEqual(color.alphaComponent, 0.4, accuracy: 0.001)
    }

    @MainActor
    func testReleaseFadesToZeroBeforeHiding() async throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 160, height: 120)] })
        defer { overlay.stop() }
        overlay.show()
        let panel = try XCTUnwrap(overlay.panels.first)
        overlay.hide()
        XCTAssertFalse(overlay.isVisible)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.contentView?.layer?.opacity, 0)
        let layer = try XCTUnwrap(panel.contentView?.layer)
        let animation = try XCTUnwrap(layer.animationKeys()?.compactMap {
            layer.animation(forKey: $0) as? CABasicAnimation
        }.first(where: { $0.keyPath == "opacity" }))
        XCTAssertEqual(animation.duration, 0.222)
        XCTAssertEqual(animation.toValue as? Float, 0)
        CATransaction.flush()
        for _ in 0..<100 {
            if !panel.isVisible { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testRepressDuringFadeOutDoesNotHideTheNewOverlay() async throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 160, height: 120)] })
        defer { overlay.stop() }
        overlay.show()
        let panel = try XCTUnwrap(overlay.panels.first)
        overlay.hide()
        overlay.show()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(overlay.isVisible)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.contentView?.layer?.opacity, 1)
    }

    @MainActor
    func testDisplayChangesReplacePanelsAndKeepVisibleCoverage() {
        var frames = [NSRect(x: 0, y: 0, width: 160, height: 120)]
        let overlay = DesktopOverlayController(screenFrames: { frames })
        defer { overlay.stop() }
        overlay.show()
        let oldPanels = overlay.panels
        frames.append(NSRect(x: -200, y: 0, width: 200, height: 150))
        overlay.refreshScreens()
        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(overlay.panels.map(\.frame), frames)
        XCTAssertTrue(overlay.panels.allSatisfy(\.isVisible))
        XCTAssertTrue(oldPanels.allSatisfy { !$0.isVisible })
        frames.removeFirst()
        overlay.refreshScreens()
        XCTAssertEqual(overlay.panels.map(\.frame), frames)
        XCTAssertEqual(overlay.panels.count, 1)
    }

    @MainActor
    func testStoppingClosesEveryPanelAndCanRestart() {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 160, height: 120)] })
        overlay.show()
        let oldPanels = overlay.panels
        overlay.stop()
        XCTAssertFalse(overlay.isVisible)
        XCTAssertTrue(overlay.panels.isEmpty)
        XCTAssertTrue(oldPanels.allSatisfy { !$0.isVisible })
        overlay.stop()
        overlay.show()
        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(overlay.panels.count, 1)
        overlay.stop()
    }
}
