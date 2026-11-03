import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Inserts text into the frontmost app without activating TalkToPrompt.
@MainActor
final class ClipboardTextInserter {
    enum InsertionError: LocalizedError {
        case permissionRequired
        case clipboardReadFailed
        case clipboardWriteFailed
        case clipboardRestoreFailed
        case clipboardChanged
        case focusChanged
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return "Enable TalkToPrompt in Privacy & Security → Accessibility to paste text."
            case .clipboardReadFailed:
                return "The clipboard could not be backed up. No text was pasted."
            case .clipboardWriteFailed:
                return "The text could not be copied to the clipboard."
            case .clipboardRestoreFailed:
                return "The previous clipboard contents could not be restored."
            case .clipboardChanged:
                return "The clipboard changed before pasting. The new clipboard contents were kept."
            case .focusChanged:
                return "The focused app changed before pasting. No text was pasted."
            case .eventCreationFailed:
                return "The Paste keyboard shortcut could not be created."
            }
        }
    }

    private typealias ClipboardBackup = [[NSPasteboard.PasteboardType: Data]]
    private let pasteboard: NSPasteboard
    private let hasPermission: () -> Bool
    private let frontmostPID: () -> pid_t?
    private let postEvent: (CGEvent) -> Void
    private let pause: () async throws -> Void
    private var lastInsertion: Task<Void, Error>?
    private var pendingBackup: (contents: ClipboardBackup, changeCount: Int)?

    init(
        pasteboard: NSPasteboard = .general,
        hasPermission: @escaping () -> Bool = CGPreflightPostEventAccess,
        frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
        pause: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(111)) }
    ) {
        self.pasteboard = pasteboard
        self.hasPermission = hasPermission
        self.frontmostPID = frontmostPID
        self.postEvent = postEvent
        self.pause = pause
    }

    /// Serializes callers, preserving the clipboard across each insertion.
    /// Cancellation restores the clipboard if this operation still owns it.
    func insert(_ text: String) async throws {
        let targetPID = frontmostPID()
        let previous = lastInsertion
        let insertion = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await self.performInsertion(text, targetPID: targetPID)
        }
        lastInsertion = insertion
        try await withTaskCancellationHandler {
            try await insertion.value
        } onCancel: {
            insertion.cancel()
        }
    }

    /// Synchronous cleanup for application termination, which cannot wait for
    /// cancelled async tasks to resume. Cancel callers before invoking this.
    @discardableResult
    func restorePendingClipboard() -> Bool {
        guard let pendingBackup else { return true }
        self.pendingBackup = nil
        return pasteboard.changeCount != pendingBackup.changeCount
            || restoreClipboard(pendingBackup.contents)
    }

    private func performInsertion(_ text: String, targetPID: pid_t?) async throws {
        guard hasPermission() else { throw InsertionError.permissionRequired }
        guard let targetPID, frontmostPID() == targetPID else { throw InsertionError.focusChanged }
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { throw InsertionError.eventCreationFailed }
        // Use Command alone even if the other physical Shift key is still held.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        let originalChangeCount = pasteboard.changeCount
        let backup = try backupClipboard()
        guard pasteboard.changeCount == originalChangeCount else { throw InsertionError.clipboardChanged }
        try Task.checkCancellation()

        pasteboard.clearContents()
        let didWrite = pasteboard.setString(text, forType: .string)
        let ownedChangeCount = pasteboard.changeCount
        pendingBackup = (backup, ownedChangeCount)
        var insertionError: Error?
        do {
            guard didWrite else { throw InsertionError.clipboardWriteFailed }
            // Let the clipboard settle before the destination receives ⌘V.
            try await pause()
            try Task.checkCancellation()
            guard hasPermission() else { throw InsertionError.permissionRequired }
            guard frontmostPID() == targetPID else { throw InsertionError.focusChanged }
            guard pasteboard.changeCount == ownedChangeCount else { throw InsertionError.clipboardChanged }
            postEvent(keyDown)
            postEvent(keyUp)
            // Give the destination time to read the clipboard before restoring.
            try await pause()
            try Task.checkCancellation()
        } catch {
            insertionError = error
        }

        // A user or another app may have copied something during either delay.
        // Never replace newer clipboard contents with our older backup.
        let restored = restorePendingClipboard()
        if let insertionError { throw insertionError }
        if !restored { throw InsertionError.clipboardRestoreFailed }
    }

    private func backupClipboard() throws -> ClipboardBackup {
        guard let items = pasteboard.pasteboardItems else { throw InsertionError.clipboardReadFailed }
        // Materialize data now: pasteboard items become invalid after clearContents.
        // Preserve rich text and other representations alongside the original text.
        return try items.map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw InsertionError.clipboardReadFailed }
                representations[type] = data
            }
            return representations
        }
    }

    private func restoreClipboard(_ backup: ClipboardBackup) -> Bool {
        let items = backup.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return items.isEmpty || pasteboard.writeObjects(items)
    }
}
