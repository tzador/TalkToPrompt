import AppKit
import QuartzCore
import XCTest
@testable import TalkToPrompt

final class DesktopOverlayControllerTests: XCTestCase {
    @MainActor
    func testListeningDotsAnimateWithoutResettingWhenCounterUpdates() async throws {
        let overlay = DesktopOverlayController(screenFrames: { [NSRect(x: 0, y: 0, width: 800, height: 600)] })
        defer { overlay.stop() }
        overlay.start()
        overlay.setMessage("Listening... 0 seconds")
        let view = try XCTUnwrap(overlay.panels.first?.contentView as? DesktopOverlayController.OverlayContentView)
        view.layoutSubtreeIfNeeded()
        let initialFrame = view.statusLabel.frame
        let firstDot = ("Listening" as NSString).length
        func firstDotColor() -> NSColor? {
            view.statusLabel.attributedStringValue.attribute(.foregroundColor, at: firstDot, effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(firstDotColor(), .clear)
        for _ in 0..<100 {
            if firstDotColor() == .white { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(firstDotColor(), .white)
        overlay.setMessage("Listening... 1 seconds")
        XCTAssertEqual(firstDotColor(), .white)
        XCTAssertEqual(view.counterLabel.stringValue, "1 seconds")
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.statusLabel.frame, initialFrame)
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
            XCTAssertEqual(view.counterLabel.font?.pointSize, 28)
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
        XCTAssertEqual(view.statusLabel.stringValue, "Listening...")
        XCTAssertEqual(view.statusLabel.font?.pointSize, 64)
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
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertEqual(panel.contentView?.layer?.opacity, 0)
        }
    }

    @MainActor
    func testShowFadesBlackToTwentyFivePercentWithoutBlurOver222Milliseconds() throws {
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
        XCTAssertEqual(content.backgroundTint.layer?.opacity, 0.25)
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
