import AppKit
import QuartzCore
import XCTest
@testable import TalkToPrompt

final class DesktopOverlayControllerTests: XCTestCase {
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
    func testShowFadesWhiteToEightyPercentOver222Milliseconds() throws {
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
        XCTAssertEqual(content.backdrop.blendingMode, .behindWindow)
        XCTAssertEqual(content.backdrop.material, .fullScreenUI)
        XCTAssertEqual(content.backdrop.state, .active)
        XCTAssertEqual(content.whiteTint.layer?.opacity, 0.8)
        let background = try XCTUnwrap(content.whiteTint.layer?.backgroundColor)
        let color = try XCTUnwrap(NSColor(cgColor: background)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 1)
        XCTAssertEqual(color.greenComponent, 1)
        XCTAssertEqual(color.blueComponent, 1)
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
