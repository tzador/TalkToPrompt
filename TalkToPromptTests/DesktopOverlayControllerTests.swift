import AppKit
import QuartzCore
import XCTest
@testable import TalkToPrompt

final class DesktopOverlayControllerTests: XCTestCase {
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
        overlay.appendIntensities([1, 0.2, 0.5])
        XCTAssertEqual(overlay.currentIntensity, 0.5)
        let bounds = try XCTUnwrap(visualization.circle.path).boundingBox
        XCTAssertEqual(bounds.width / 2, visualization.centralRadius * (1 + 0.5 * AudioVisualizationView.intensityGain), accuracy: 0.001)
        XCTAssertEqual(bounds.midX, view.bounds.midX, accuracy: 0.001)
        XCTAssertEqual(bounds.midY, view.bounds.midY, accuracy: 0.001)
        XCTAssertEqual(visualization.geometryLayer.animation(forKey: "radiusScale")?.duration, DesktopOverlayController.fadeDuration)
        overlay.appendIntensities([0])
        XCTAssertEqual(visualization.circle.path?.boundingBox.width, visualization.centralRadius * 2)
        overlay.setMessage("Transcribing...")
        overlay.appendIntensities([1])
        XCTAssertEqual(overlay.currentIntensity, 0)
        XCTAssertEqual(visualization.circle.path?.boundingBox.width, visualization.centralRadius * 2)
        XCTAssertNotNil(visualization.circle.animation(forKey: "processingPulse"))
        overlay.hide()
        let exit = try XCTUnwrap(visualization.geometryLayer.animation(forKey: "radiusScale") as? CABasicAnimation)
        XCTAssertEqual(exit.duration, DesktopOverlayController.fadeDuration)
        XCTAssertEqual((exit.toValue as? NSNumber)?.doubleValue, 0)
        overlay.hideImmediately()
        XCTAssertNil(visualization.geometryLayer.animation(forKey: "radiusScale"))
        XCTAssertNil(visualization.circle.animation(forKey: "processingPulse"))
    }

    @MainActor
    func testBufferWarningMetricsAndVolumeAreInheritedAcrossScreensAndReset() throws {
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
            XCTAssertEqual(view.counterLabel.stringValue, "625 seconds")
            XCTAssertEqual(view.bufferLabel.stringValue, "83.3% buffer used")
            XCTAssertEqual(view.bufferLabel.textColor, NSColor.white.withAlphaComponent(0.7))
            XCTAssertEqual(view.remainingLabel.stringValue, "~125 seconds remaining")
            XCTAssertFalse(view.bufferLabel.isHidden)
            XCTAssertFalse(view.remainingLabel.isHidden)
            XCTAssertLessThan(view.bufferLabel.frame.maxY, view.counterLabel.frame.minY)
            XCTAssertLessThan(view.remainingLabel.frame.maxY, view.bufferLabel.frame.minY)
        }
        overlay.setMessage("Transcribing...")
        for panel in overlay.panels {
            let view = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
            XCTAssertTrue(view.bufferLabel.isHidden)
            XCTAssertTrue(view.remainingLabel.isHidden)
            XCTAssertTrue(view.visualization.isWarning)
        }
        overlay.setBufferUsage(.empty)
        overlay.setMessage("Listening... 0 seconds")
        for panel in overlay.panels {
            let view = try XCTUnwrap(panel.contentView as? DesktopOverlayController.OverlayContentView)
            XCTAssertFalse(view.visualization.isWarning)
            XCTAssertEqual(view.visualization.circle.fillColor, NSColor.white.cgColor)
            XCTAssertEqual(view.bufferLabel.stringValue, "0.0% buffer used")
            XCTAssertEqual(view.remainingLabel.stringValue, "~749 seconds remaining")
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
