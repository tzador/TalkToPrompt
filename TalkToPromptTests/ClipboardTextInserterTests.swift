import AppKit
import CoreGraphics
import XCTest
@testable import TalkToPrompt

final class ClipboardTextInserterTests: XCTestCase {
    @MainActor
    private func clipboard(_ text: String? = "Original clipboard") -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        if let text { pasteboard.setString(text, forType: .string) }
        return pasteboard
    }

    @MainActor
    func testArbitraryTextIsPastedAndRichClipboardRestoredWithDefaultDelays() async throws {
        let pasteboard = clipboard()
        defer { pasteboard.releaseGlobally() }
        let originalRTF = Data("{\\rtf1 Original clipboard}".utf8)
        pasteboard.setData(originalRTF, forType: .rtf)
        let text = "hello, world\nGrüße 👋 你好"
        var events: [CGEvent] = []
        let inserter = ClipboardTextInserter(
            pasteboard: pasteboard,
            hasPermission: { true },
            frontmostPID: { 123 },
            postEvent: { event in
                XCTAssertEqual(pasteboard.string(forType: .string), text)
                events.append(event)
            }
        )
        let clock = ContinuousClock()
        let start = clock.now
        try await inserter.insert(text)
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .milliseconds(222))
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertTrue(events.allSatisfy { $0.flags == .maskCommand })
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 9 })
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
        XCTAssertEqual(pasteboard.data(forType: .rtf), originalRTF)
    }

    @MainActor
    func testEmptyClipboardIsRestoredToEmpty() async throws {
        let pasteboard = clipboard(nil)
        defer { pasteboard.releaseGlobally() }
        let inserter = ClipboardTextInserter(
            pasteboard: pasteboard, hasPermission: { true }, frontmostPID: { 123 },
            postEvent: { _ in }, pause: {}
        )
        try await inserter.insert("Temporary text")
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    @MainActor
    func testMissingPermissionDoesNotTouchClipboardOrPostEvents() async {
        let pasteboard = clipboard()
        defer { pasteboard.releaseGlobally() }
        let changeCount = pasteboard.changeCount
        let inserter = ClipboardTextInserter(
            pasteboard: pasteboard, hasPermission: { false }, frontmostPID: { 123 },
            postEvent: { _ in XCTFail("Must not post without permission") }, pause: {}
        )
        do {
            try await inserter.insert("Not allowed")
            XCTFail("Expected permission error")
        } catch {
            XCTAssertEqual(error as? ClipboardTextInserter.InsertionError, .permissionRequired)
        }
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testFocusChangeAbortsAndRestoresClipboard() async {
        let pasteboard = clipboard()
        defer { pasteboard.releaseGlobally() }
        var pid: pid_t = 123
        let inserter = ClipboardTextInserter(
            pasteboard: pasteboard, hasPermission: { true }, frontmostPID: { pid },
            postEvent: { _ in XCTFail("Must not paste into another app") },
            pause: { pid = 456 }
        )
        do {
            try await inserter.insert("Wrong destination")
            XCTFail("Expected focus error")
        } catch {
            XCTAssertEqual(error as? ClipboardTextInserter.InsertionError, .focusChanged)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testNewClipboardBeforePasteIsKeptWithoutPosting() async {
        let pasteboard = clipboard()
        defer { pasteboard.releaseGlobally() }
        let inserter = ClipboardTextInserter(
            pasteboard: pasteboard, hasPermission: { true }, frontmostPID: { 123 },
            postEvent: { _ in XCTFail("Must not paste unrelated clipboard contents") },
            pause: {
                pasteboard.clearContents()
                pasteboard.setString("Newly copied text", forType: .string)
            }
        )
        do {
            try await inserter.insert("Temporary text")
            XCTFail("Expected clipboard change error")
        } catch {
            XCTAssertEqual(error as? ClipboardTextInserter.InsertionError, .clipboardChanged)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "Newly copied text")
    }

    @MainActor
    func testNewClipboardAfterPasteIsKept() async throws {
        let pasteboard = clipboard()
        defer { pasteboard.releaseGlobally() }
        var pauses = 0
        var events = 0
        let inserter = ClipboardTextInserter(
            pasteboard: pasteboard, hasPermission: { true }, frontmostPID: { 123 },
            postEvent: { _ in events += 1 },
            pause: {
                pauses += 1
                if pauses == 2 {
                    pasteboard.clearContents()
                    pasteboard.setString("Newly copied text", forType: .string)
                }
            }
        )
        try await inserter.insert("Temporary text")
        XCTAssertEqual(events, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "Newly copied text")
    }

    @MainActor
    func testCancellationRestoresClipboardWithoutPosting() async {
        let pasteboard = clipboard()
        defer { pasteboard.releaseGlobally() }
        let reachedDelay = expectation(description: "Temporary clipboard written")
        let inserter = ClipboardTextInserter(
            pasteboard: pasteboard, hasPermission: { true }, frontmostPID: { 123 },
            postEvent: { _ in XCTFail("Cancelled insertion must not post") },
            pause: {
                reachedDelay.fulfill()
                try await Task.sleep(for: .seconds(10))
            }
        )
        let task = Task { try await inserter.insert("Temporary text") }
        await fulfillment(of: [reachedDelay], timeout: 2)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testTerminationCanRestoreClipboardBeforeCancelledTaskResumes() async {
        let pasteboard = clipboard()
        defer { pasteboard.releaseGlobally() }
        let reachedDelay = expectation(description: "Temporary clipboard written")
        let inserter = ClipboardTextInserter(
            pasteboard: pasteboard, hasPermission: { true }, frontmostPID: { 123 },
            postEvent: { _ in XCTFail("Cancelled insertion must not post") },
            pause: {
                reachedDelay.fulfill()
                try await Task.sleep(for: .seconds(10))
            }
        )
        let task = Task { try await inserter.insert("Temporary text") }
        await fulfillment(of: [reachedDelay], timeout: 2)
        task.cancel()
        XCTAssertTrue(inserter.restorePendingClipboard())
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
        _ = try? await task.value
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testConcurrentInsertionsAreSerialized() async throws {
        let pasteboard = clipboard()
        defer { pasteboard.releaseGlobally() }
        var pastedTexts: [String] = []
        let inserter = ClipboardTextInserter(
            pasteboard: pasteboard, hasPermission: { true }, frontmostPID: { 123 },
            postEvent: { event in
                if event.type == .keyDown {
                    pastedTexts.append(pasteboard.string(forType: .string)!)
                }
            }
        )
        let first = Task { try await inserter.insert("First") }
        await Task.yield()
        let second = Task { try await inserter.insert("Second") }
        try await first.value
        try await second.value
        XCTAssertEqual(pastedTexts, ["First", "Second"])
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }
}
