import AppKit
import XCTest
@testable import TalkToPrompt

final class MenuBarIconTests: XCTestCase {
    @MainActor
    func testReadinessIndicatorDrawsSolidGreenOrRedDot() throws {
        let indicator = MenuBarIcon.ReadinessIndicator(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        for state in [MenuBarIcon.State.ready, .missingRequirements] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            indicator.state = state
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            indicator.draw(indicator.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let color = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4))
            XCTAssertGreaterThan(color.alphaComponent, 0.95)
            if state == .ready {
                XCTAssertGreaterThan(color.greenComponent, color.redComponent)
                XCTAssertGreaterThan(color.greenComponent, color.blueComponent)
            } else {
                XCTAssertGreaterThan(color.redComponent, color.greenComponent)
                XCTAssertGreaterThan(color.redComponent, color.blueComponent)
            }
        }
    }

    @MainActor
    func testAllRequirementsAreNeededForReadyIndicator() {
        for bits in 0..<16 {
            let state = MenuBarIcon.State.permissions(
                inputMonitoring: bits & 1 != 0, accessibility: bits & 2 != 0,
                microphone: bits & 4 != 0, apiKey: bits & 8 != 0
            )
            XCTAssertEqual(state, bits == 15 ? .ready : .missingRequirements)
        }
    }

    @MainActor
    func testMenuBarArtworkHasTransparentBackgroundAndNeutralSymbols() throws {
        do {
            let image = try XCTUnwrap(MenuBarIcon.statusImage())
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size.height, 18)
            XCTAssertLessThan(image.size.width, 26)
            var rect = NSRect(origin: .zero, size: image.size)
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            var transparent = 0
            var colored = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                    if color.alphaComponent < 0.01 { transparent += 1 }
                    if color.alphaComponent > 0.8 {
                        XCTAssertEqual(color.redComponent, 0, accuracy: 0.03)
                        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.03)
                        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.03)
                        colored += 1
                    }
                }
            }
            XCTAssertGreaterThan(transparent, 50)
            XCTAssertGreaterThan(colored, 20)
        }
    }
}
