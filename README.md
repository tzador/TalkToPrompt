# TalkToPrompt

A native macOS SwiftUI app with a single window and a centered **Play Beep** button. Pressing it plays a 440 Hz sine wave for one second. Closing the window quits the app and stops keyboard monitoring.

The window has a fixed 720 × 720 point content area and cannot be resized. A persistent top status area shows **Input Monitoring** and **Accessibility** as stacked, full-width rounded bubbles, with one **Open System Settings** button for each permission. Each bubble uses orange text and an orange outline when permission is missing, or green when granted. macOS measures window layout in points; Retina displays render these at their display scale.

While the app is running, holding **left Shift + right Shift** plays a one-second **440 Hz** sine wave. Releasing either Shift plays a one-second **880 Hz** sine wave and pastes **hello, world** into the currently focused app when Accessibility permission is granted. Either press order works; keeping the keys held does not repeat the sound. The two tones can overlap if you release quickly, so each can finish its full second. Repeating the same tone restarts it.

## Keyboard permissions

At startup, the app checks Input Monitoring and event-posting permission. If a missing permission has never been requested, it explains both permissions and offers an **Open System Settings** button for each missing permission, plus **Not Now**. Each Settings button requests access if missing and opens the corresponding macOS Settings pane; the app cannot grant permission itself. Declining a request leaves a reminder in the window without repeatedly showing the startup explanation.

In **System Settings → Privacy & Security → Input Monitoring**, enable **TalkToPrompt**. The app rechecks when you return and periodically while running. If macOS asks you to quit and reopen the app, do so. If access is enabled but monitoring cannot start, quit and reopen the app. The **Open System Settings** beside Input Monitoring button in the status bar always opens its Settings pane.

Monitoring works while other apps have focus. It uses a passive event tap for modifier changes only, does not record typed text, and does not intercept keyboard input. The **Play Beep** button works without permission. macOS may restrict monitoring during protected input, such as password entry.

Event-posting permission is shown under **System Settings → Privacy & Security → Accessibility**. Use **Open System Settings** beside Accessibility in the startup explanation or status bar to request access if missing and open Settings so you can enable **TalkToPrompt**. Its status is rechecked when you return and periodically while running. Follow any macOS quit-and-reopen instructions. This permission is required for automatic pasting when the Shift chord is released. Missing Accessibility permission does not block the Shift tones. If you open Accessibility settings while access is missing, returning to TalkToPrompt shows an in-app **Restart** / **Not Now** prompt, even if macOS does not offer to restart. Choose Restart after enabling the toggle. The app restores any pending clipboard backup and launches a replacement instance before quitting; if launching fails, the current app stays open and displays an error.

## Clipboard text insertion

`ClipboardTextInserter.swift` provides `try await inserter.insert(text)` for arbitrary Unicode or multiline text. It backs up clipboard contents (including available rich-text representations), writes the supplied text, waits **111 ms**, posts **⌘V**, waits another **111 ms**, and restores the backup. Its synthetic Paste shortcut uses Command alone, even if a physical Shift key is still held. Calls are serialized so repeated shortcuts do not corrupt the backup.

If another app or the user copies new content during the operation, the helper keeps that newer clipboard rather than overwriting it. It aborts before pasting if focus switches to another app, permission is revoked, or the clipboard changes. Cancellation and normal app termination restore any clipboard contents still owned by the helper.

The destination must have an editable field that accepts Paste. The delays allow time for the destination to read the clipboard; macOS does not confirm whether another app accepted the paste, and some apps may need a longer delay.

## Run in Xcode

1. Open `TalkToPrompt.xcodeproj`.
2. Select the **TalkToPrompt** scheme and **My Mac** destination.
3. Press **⌘R**.

Requires macOS 14 or later and Xcode 15 or later. There are no external dependencies or microphone permissions. The app uses normal macOS Dock and menu bar behavior.

For distribution, select your Apple development team in the target's **Signing & Capabilities** settings. Local development uses ad hoc signing and needs no team.

## Build from Terminal

```sh
make run    # Build and launch the app
make build  # Build only (also the default for `make`)
make test   # Run keyboard state, tone, and permission-flow tests
make clean  # Clean build products
```

Build and launch an optimized Release version with `make run CONFIGURATION=Release`.

`TalkToPromptApp.swift` defines the single-window lifecycle, `ContentView.swift` defines the UI and permission guidance, `ShiftMonitor.swift` manages permission and global modifier monitoring, `BeepPlayer.swift` generates and plays the tones using AVFoundation, and `ClipboardTextInserter.swift` handles clipboard-backed pasting. SwiftUI's `Window` scene automatically quits the app when its sole window closes.

During development, keep the bundle identifier and build location stable. macOS ties privacy grants to the app's identity; rebuilding an ad hoc signed app can require enabling access again. Use a consistent Apple development signing identity for more stable permission testing.
