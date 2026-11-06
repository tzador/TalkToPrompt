import AppKit
import QuartzCore
import XCTest
@testable import TalkToPrompt

final class DesktopOverlayControllerTests: XCTestCase {
    @MainActor
    func testGeometryGrowsAndShrinksWithOverlayFadeAndStatusCrossfades() throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 800, height: 800)] })
        defer { overlay.stop() }
        overlay.setListening(true)
        overlay.show()
        let view = try XCTUnwrap(overlay.panels.first?.contentView as? DesktopOverlayController.OverlayContentView)
        view.layoutSubtreeIfNeeded()
        let geometry = view.visualization.geometryLayer
        let entrance = try XCTUnwrap(geometry.animation(forKey: "radiusScale") as? CABasicAnimation)
        XCTAssertEqual(entrance.duration, DesktopOverlayController.fadeDuration)
        XCTAssertEqual((entrance.fromValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((entrance.toValue as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual(view.statusLabel.font?.pointSize, 54)
        overlay.appendIntensities(Array(repeating: 0.8, count: 32))
        // Live 10 ms updates must not replace the slower entrance animation.
        XCTAssertEqual(geometry.animation(forKey: "radiusScale")?.duration, DesktopOverlayController.fadeDuration)
        overlay.setMessage("Transcribing...")
        let crossfade = try XCTUnwrap(view.captionSurface.layer?.animation(forKey: "transition") as? CATransition)
        XCTAssertEqual(crossfade.type, .fade)
        XCTAssertEqual(crossfade.duration, DesktopOverlayController.fadeDuration)
        XCTAssertEqual(view.statusLabel.font?.pointSize, 36)
        XCTAssertNotNil(view.visualization.circle.animation(forKey: "processingPulse"))
        overlay.hide()
        let exit = try XCTUnwrap(geometry.animation(forKey: "radiusScale") as? CABasicAnimation)
        XCTAssertEqual(exit.duration, DesktopOverlayController.fadeDuration)
        XCTAssertEqual((exit.toValue as? NSNumber)?.doubleValue, 0)
        overlay.show()
        let reopened = try XCTUnwrap(geometry.animation(forKey: "radiusScale") as? CABasicAnimation)
        XCTAssertEqual((reopened.toValue as? NSNumber)?.doubleValue, 1)
        overlay.hideImmediately()
        XCTAssertNil(geometry.animation(forKey: "radiusScale"))
        XCTAssertEqual((geometry.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue, 0)
    }

    @MainActor
    func testAudioHistoryMatchesAcrossScreensAndCollapsesDuringProcessing() throws {
        var frames = [NSRect(x: 0, y: 0, width: 800, height: 800)]
        let overlay = DesktopOverlayController(screenFrames: { frames })
        defer { overlay.stop() }
        overlay.start()
        overlay.setMessage("Listening... 3 seconds")
        let values = (0..<32).map { Float($0 % 5) / 4 }
        overlay.appendIntensities(values)
        frames.append(NSRect(x: -800, y: 0, width: 800, height: 800))
        overlay.refreshScreens()
        var radii: [[CGFloat]] = []
        for panel in overlay.panels {
            let view = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
            view.layoutSubtreeIfNeeded()
            let visualization = view.visualization
            XCTAssertFalse(visualization.isHidden)
            XCTAssertEqual(visualization.rings.count, 32)
            var innerRadius = visualization.centralRadius
            for (index, ring) in visualization.rings.enumerated() {
                let displacedRadius = visualization.centralRadius + CGFloat(index + 1) * visualization.radiusStep
                    + CGFloat(values[31 - index]) * visualization.maximumDisplacement * 2
                let expectedRadius = max(displacedRadius, innerRadius + visualization.radiusStep * 0.15)
                let bounds = try XCTUnwrap(ring.path).boundingBox
                XCTAssertEqual(bounds.width / 2, expectedRadius, accuracy: 0.001)
                XCTAssertEqual(bounds.midX, view.bounds.midX, accuracy: 0.001)
                XCTAssertEqual(bounds.midY, view.bounds.midY, accuracy: 0.001)
                XCTAssertNil(ring.strokeColor)
                XCTAssertEqual(ring.fillRule, .evenOdd)
                let fade = max(0, 1 - CGFloat(index) / 30)
                let opacity = index.isMultiple(of: 2) ? CGFloat(AudioHistoryVisualizationView.centralOpacity) * fade : 0
                XCTAssertEqual(try XCTUnwrap(ring.fillColor).alpha, opacity, accuracy: 0.001)
                let color = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(ring.fillColor))?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(color.redComponent, 1)
                XCTAssertEqual(color.greenComponent, 1)
                XCTAssertEqual(color.blueComponent, 1)
                let path = try XCTUnwrap(ring.path)
                XCTAssertFalse(path.contains(CGPoint(x: bounds.midX, y: bounds.midY), using: .evenOdd))
                let bandMidpoint = CGPoint(x: bounds.midX + (innerRadius + expectedRadius) / 2, y: bounds.midY)
                XCTAssertTrue(path.contains(bandMidpoint, using: .evenOdd))
                innerRadius = expectedRadius
            }
            XCTAssertEqual(visualization.circle.opacity, 0.45, accuracy: 0.001)
            XCTAssertEqual(visualization.centralRadius, 180, accuracy: 0.001)
            XCTAssertGreaterThan(visualization.radiusStep, 5.5)
            XCTAssertTrue(visualization.geometryLayer.sublayers?.last === visualization.circle)
            radii.append(visualization.rings.map { $0.path!.boundingBox.width / 2 })
        }
        XCTAssertEqual(radii[0], radii[1])
        overlay.setMessage("Transcribing...")
        overlay.appendIntensities(Array(repeating: 1, count: 32)) // A late audio update must not reopen rings.
        for panel in overlay.panels {
            let view = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
            for ring in view.visualization.rings {
                XCTAssertEqual(try XCTUnwrap(ring.path).boundingBox.width / 2, view.visualization.centralRadius, accuracy: 0.001)
                XCTAssertEqual(ring.opacity, 0)
                let animation = try XCTUnwrap(ring.animation(forKey: "path") as? CABasicAnimation)
                XCTAssertEqual(animation.duration, AudioHistoryVisualizationView.collapseDuration)
                XCTAssertNotNil(ring.animation(forKey: "opacity"))
            }
            XCTAssertNotNil(view.visualization.circle.animation(forKey: "processingPulse"))
            XCTAssertFalse(view.visualization.isHidden)
        }
        overlay.hideImmediately()
        for panel in overlay.panels {
            let view = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
            XCTAssertTrue(view.visualization.isHidden)
            XCTAssertNil(view.visualization.circle.animation(forKey: "processingPulse"))
        }
    }

    @MainActor
    func testHistoryImpulseMovesOutwardAndOlderCirclesAlwaysStayLarger() throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 800, height: 800)] })
        defer { overlay.stop() }
        overlay.start()
        overlay.setListening(true)
        let view = try XCTUnwrap(overlay.panels.first?.contentView as? DesktopOverlayController.OverlayContentView)
        view.layoutSubtreeIfNeeded()
        let center = try XCTUnwrap(view.visualization.circle.path).boundingBox
        overlay.appendIntensities([1])
        for age in 0..<32 {
            let expected = (0..<32).map { Float($0 == age ? 1 : 0) }
            XCTAssertEqual(overlay.intensityHistory, expected)
            var previousRadius = view.visualization.centralRadius
            for (index, ring) in view.visualization.rings.enumerated() {
                let radius = try XCTUnwrap(ring.path).boundingBox.width / 2
                XCTAssertGreaterThan(radius, previousRadius)
                let baseline = view.visualization.centralRadius + CGFloat(index + 1) * view.visualization.radiusStep
                let displacedRadius = baseline + CGFloat(expected[index]) * view.visualization.maximumDisplacement * 2
                XCTAssertEqual(radius, max(displacedRadius, previousRadius + view.visualization.radiusStep * 0.15), accuracy: 0.001)
                previousRadius = radius
            }
            XCTAssertEqual(view.visualization.circle.path?.boundingBox, center)
            overlay.appendIntensities([0])
        }
        XCTAssertEqual(overlay.intensityHistory, Array(repeating: 0, count: 32))
        overlay.appendIntensities([0.1, 0.2, 0.3])
        XCTAssertEqual(Array(overlay.intensityHistory.prefix(3)), [0.3, 0.2, 0.1])
        overlay.setMessage("Transcribing...")
        overlay.appendIntensities([1])
        XCTAssertEqual(overlay.intensityHistory, Array(repeating: 0, count: 32))
        overlay.setListening(true)
        XCTAssertEqual(overlay.intensityHistory, Array(repeating: 0, count: 32))
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
            XCTAssertEqual(color(at: 0), .white)
            for _ in 0..<100 {
                if color(at: 1) == .white { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(color(at: 1), .white)
            overlay.setMessage(update)
            XCTAssertEqual(color(at: 1), .white)
            for step in 0...word.count {
                view.setHighlightedLetter(step)
                for index in 0..<word.count {
                    XCTAssertEqual(color(at: index), index == step % word.count ? .white : .white.withAlphaComponent(0.55))
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
            XCTAssertEqual(view.counterLabel.stringValue, "4 seconds")
            XCTAssertFalse(view.counterLabel.isHidden)
            XCTAssertEqual(view.counterLabel.font?.pointSize, 20)
            XCTAssertEqual(view.counterLabel.textColor, NSColor.white.withAlphaComponent(0.7))
            let font = try XCTUnwrap(view.counterLabel.font)
            XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            view.layoutSubtreeIfNeeded()
            XCTAssertLessThan(view.counterLabel.frame.maxY, view.statusLabel.frame.minY)
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
    func testListeningCaptionIsLargeWhiteAndCenteredOnlyWhenRequested() throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 800, height: 600)] })
        defer { overlay.stop() }
        overlay.start()
        let view = try XCTUnwrap(overlay.panels.first?.contentView as? DesktopOverlayController.OverlayContentView)
        XCTAssertTrue(view.statusLabel.isHidden)
        overlay.setListening(true)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.statusLabel.stringValue, "Listening")
        XCTAssertEqual(view.statusLabel.font?.pointSize, 54)
        XCTAssertEqual(view.statusLabel.textColor, .white)
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
        XCTAssertEqual(content.backgroundTint.layer?.opacity, 0.40)
        let background = try XCTUnwrap(content.backgroundTint.layer?.backgroundColor)
        let color = try XCTUnwrap(NSColor(cgColor: background)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 0)
        XCTAssertEqual(color.greenComponent, 0)
        XCTAssertEqual(color.blueComponent, 0)
        XCTAssertEqual(color.alphaComponent, 1)
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
