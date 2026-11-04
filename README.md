# TalkToPrompt

A native macOS SwiftUI app with a single window for keyboard permissions and API key configuration. Closing the window quits the app and stops keyboard monitoring.

The window has a fixed 720 × 720 point content area and cannot be resized. A persistent top status area shows **Input Monitoring**, **Accessibility**, **Microphone**, and **OpenAI API Key**, in that order, as stacked, full-width rounded bubbles, with one **Open System Settings** button for each permission and an **Enter** or **Clear** button for the API key. Each bubble uses orange text and an orange outline when permission is missing, or green when granted. macOS measures window layout in points; Retina displays render these at their display scale.

Hold **left Shift + right Shift** to start a session. Every connected screen shows the overlay, and the rising 440 → 880 Hz cue plays. Once microphone samples arrive, the center heading shows **Listening...**, with elapsed seconds on a separate, smaller, regular-weight gray line below. The counter updates as recording continues.

Release either Shift to release the microphone and play the captured audio back from memory. The overlay remains open with **Speaking...** and the same separate gray seconds counter, measured from the playback clock. When playback completes, the overlay fades away over 222 ms and the falling 880 → 440 Hz exit cue plays. Further double-Shift presses and their releases are ignored while a session is open, including during playback and the closing fade. A new session can begin once the overlay has fully closed.

The full-screen panels use native backdrop blur with an 80%-opaque white tint, fading in and out over 222 ms. macOS controls the native blur radius; the animation changes its visible strength. No screen capture or Screen Recording permission is needed. Panels cover the menu bar and Dock, appear across Spaces and alongside full-screen apps, and do not take keyboard focus or intercept mouse clicks. Newly connected screens inherit the current status message.

Both cues last 222 ms with a raised-cosine volume envelope, `(1 - cos(2πt / 0.222)) / 2`: silence → peak at 111 ms → silence. Pitch changes linearly with continuous phase.

## Keyboard permissions

At startup, the app checks Input Monitoring and event-posting permission. If a missing permission has never been requested, it explains both permissions and offers an **Open System Settings** button for each missing permission, plus **Not Now**. Each Settings button requests access if missing and opens the corresponding macOS Settings pane; the app cannot grant permission itself. Declining a request leaves a reminder in the window without repeatedly showing the startup explanation.

In **System Settings → Privacy & Security → Input Monitoring**, enable **TalkToPrompt**. The app rechecks when you return and periodically while running. If macOS asks you to quit and reopen the app, do so. If access is enabled but monitoring cannot start, quit and reopen the app. The **Open System Settings** beside Input Monitoring button in the status bar always opens its Settings pane.

Monitoring works while other apps have focus. It uses a passive event tap to watch Shift keys, does not record typed text, and does not intercept keyboard input. macOS may restrict monitoring during protected input, such as password entry.

Event-posting permission is shown under **System Settings → Privacy & Security → Accessibility**. Use **Open System Settings** beside Accessibility in the startup explanation or status bar to request access if missing and open Settings so you can enable **TalkToPrompt**. Its status is rechecked when you return and periodically while running. Follow any macOS quit-and-reopen instructions. This permission is used by the clipboard insertion helper. Recording and playback need Input Monitoring and Microphone permission; the release gesture now starts playback instead of inserting placeholder text. If you open Accessibility settings while access is missing, returning to TalkToPrompt shows an in-app **Restart** / **Not Now** prompt, even if macOS does not offer to restart. Choose Restart after enabling the toggle. The app stops the current audio session and launches a replacement instance before quitting; if launching fails, the current app stays open and displays an error.

## Clipboard text insertion

The clipboard helper remains available for future text insertion; it is not invoked by the recording/playback session. `ClipboardTextInserter.swift` provides `try await inserter.insert(text)` for arbitrary Unicode or multiline text. It backs up clipboard contents (including available rich-text representations), writes the supplied text, waits **111 ms**, posts **⌘V**, waits another **111 ms**, and restores the backup. Its synthetic Paste shortcut uses Command alone, even if a physical Shift key is still held. Calls are serialized so repeated shortcuts do not corrupt the backup.

If another app or the user copies new content during the operation, the helper keeps that newer clipboard rather than overwriting it. It aborts before pasting if focus switches to another app, permission is revoked, or the clipboard changes. Cancellation restores clipboard contents still owned by the helper. A caller using it during app shutdown should also call `restorePendingClipboard()` before terminating.

The destination must have an editable field that accepts Paste. The delays allow time for the destination to read the clipboard; macOS does not confirm whether another app accepted the paste, and some apps may need a longer delay.

## Microphone recording

Pressing both Shift keys opens the overlay and starts microphone capture as quickly as the input device allows. The large black **Listening...** heading and a smaller gray seconds counter appear at the center of every screen after the first audio buffer arrives. Releasing either Shift requests capture shutdown and removes the input tap before playback begins. The overlay stays open with **Speaking... N seconds** until playback completes. Capture also stops if keyboard monitoring stops, the microphone is revoked or disconnected, or the app quits.

The **Microphone** permission bubble sits after Accessibility and before OpenAI API Key. Its **Open System Settings** button requests access on first use and opens **Privacy & Security → Microphone**. The first recording also requests permission if necessary. During the system consent prompt the overlay is temporarily hidden for readability; recording starts only if both Shift keys are still held and the session has not been cancelled when access is granted.

`MicrophoneRecorder.swift` opens and releases the audio engine off the main thread and copies native PCM chunks into owned memory. `MicrophoneRecordingSession.swift` coordinates permission and capture. `VoiceSessionController.swift` owns session phases, counters, shutdown cleanup, and duplicate-trigger suppression. `RecordedAudioPlayer.swift` creates an in-memory WAV from native PCM chunks and plays it without opening an input device or writing a file. Only the latest recording is retained in RAM (`monitor.microphone.latestRecording`); it is replaced on the next hold and discarded when the app quits. Audio is not written to disk or sent to an API. Hardware/permission tests use synthetic PCM and fake capture devices rather than recording the user's microphone.

## OpenAI API key

The API key status bubble shows **Not provided** or **Provided sk-...TqUA**, using only the key’s first three and last four characters. It is orange when missing and green when provided.

Choose **Enter** to open a secure input dialog. **OK** stores the key in the macOS Keychain as a generic-password item with account **OPENAI_API_KEY** and the app’s bundle identifier as its service. **Cancel** closes the dialog without saving. **Clear** deletes only that Keychain item. The key is loaded at startup and is never written to a preferences file or repository configuration.

## Run in Xcode

1. Open `TalkToPrompt.xcodeproj`.
2. Select the **TalkToPrompt** scheme and **My Mac** destination.
3. Press **⌘R**.

Requires macOS 14 or later and Xcode 15 or later. There are no external dependencies. Microphone recording requires permission in Privacy & Security → Microphone. The app uses normal macOS Dock and menu bar behavior.

For distribution, select your Apple development team in the target's **Signing & Capabilities** settings. Local development uses ad hoc signing and needs no team.

## Build from Terminal

```sh
make run    # Build and launch the app
make build  # Build only (also the default for `make`)
make test   # Run keyboard state, tone, and permission-flow tests
make clean  # Clean build products
```

Build and launch an optimized Release version with `make run CONFIGURATION=Release`.

`TalkToPromptApp.swift` defines the single-window lifecycle, `ContentView.swift` defines the UI and permission guidance, `ShiftMonitor.swift` manages permission and global modifier monitoring, `BeepPlayer.swift` generates and plays the tones using AVFoundation, `ClipboardTextInserter.swift` handles clipboard-backed pasting, and `DesktopOverlayController.swift` owns the per-screen overlay panels. SwiftUI's `Window` scene automatically quits the app when its sole window closes.

During development, keep the bundle identifier and build location stable. macOS ties privacy grants to the app's identity; rebuilding an ad hoc signed app can require enabling access again. Use a consistent Apple development signing identity for more stable permission testing.
