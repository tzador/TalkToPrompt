import AppKit
import XCTest
@testable import TalkToPrompt

final class DockIconControllerTests: XCTestCase {
    @MainActor
    func testAllRequirementsAreNeededForGreen() {
        for bits in 0..<16 {
            let state = DockIconController.State.permissions(
                inputMonitoring: bits & 1 != 0, accessibility: bits & 2 != 0,
                microphone: bits & 4 != 0, apiKey: bits & 8 != 0
            )
            XCTAssertEqual(state, bits == 15 ? .ready : .missingRequirements)
        }
    }

    @MainActor
    func testSwitchingAndRestoringOnlyChangesRuntimeIcon() {
        let green = NSImage(size: NSSize(width: 32, height: 32))
        let red = NSImage(size: NSSize(width: 32, height: 32))
        var applied: [NSImage?] = []
        var loads = 0
        let controller = DockIconController(loadImage: { name in
            loads += 1
            return name == "DockIconReady" ? green : red
        }, applyImage: { applied.append($0) })
        controller.update(.missingRequirements)
        controller.update(.missingRequirements)
        controller.update(.ready)
        controller.update(.missingRequirements)
        XCTAssertEqual(applied.count, 3)
        XCTAssertTrue(applied[0] === red)
        XCTAssertTrue(applied[1] === green)
        XCTAssertTrue(applied[2] === red)
        XCTAssertEqual(loads, 2)
        controller.restore()
        XCTAssertNil(applied.last!)
        controller.restore()
        XCTAssertEqual(applied.count, 4)
    }

    @MainActor
    func testCompiledIconAssetsHaveColoredSymbolsAndWhiteBackground() throws {
        for (name, expected) in [("DockIconReady", (53, 199, 89)), ("DockIconMissing", (255, 92, 96))] {
            let image = try XCTUnwrap(DockIconController.bundledImage(named: name), "Missing bundled runtime icon: \(name)")
            var rect = NSRect(x: 0, y: 0, width: 256, height: 256)
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            // Read the bitmap’s encoded sRGB components directly; colorAt labels
            // its result as calibrated RGB, so converting that NSColor changes the values.
            var colored = 0
            var white = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.9 else { continue }
                    let r = Int((color.redComponent * 255).rounded())
                    let g = Int((color.greenComponent * 255).rounded())
                    let b = Int((color.blueComponent * 255).rounded())
                    if abs(r - expected.0) < 8 && abs(g - expected.1) < 8 && abs(b - expected.2) < 8 { colored += 1 }
                    if r > 245 && g > 245 && b > 245 { white += 1 }
                }
            }
            XCTAssertGreaterThan(colored, 50, "Wrong glyph color in \(name)")
            XCTAssertGreaterThan(white, 200, "Missing white background in \(name)")
        }
    }
}
