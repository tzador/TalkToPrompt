import AppKit
import XCTest
@testable import TalkToPrompt

final class MenuBarIconTests: XCTestCase {
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
