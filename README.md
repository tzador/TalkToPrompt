# TalkToPrompt

A native macOS SwiftUI app with a single window and a centered **Play Beep** button. Pressing it plays a 440 Hz sine wave for one second. Closing the window quits the app and stops keyboard monitoring.

While the app is running, holding **left Shift + right Shift** plays a one-second **440 Hz** sine wave. Releasing either Shift plays a one-second **880 Hz** sine wave. Either press order works; keeping the keys held does not repeat the sound. The two tones can overlap if you release quickly, so each can finish its full second. Repeating the same tone restarts it.

## Input Monitoring permission

At startup, the app checks Input Monitoring permission. If it has never requested access, it explains the shortcut and offers **Enable Input Monitoring** or **Not Now**. Enabling requests access through macOS; the app cannot grant permission itself.

In **System Settings → Privacy & Security → Input Monitoring**, enable **TalkToPrompt**. The app rechecks when you return and periodically while running. If macOS asks you to quit and reopen the app, do so. If access is enabled but monitoring cannot start, quit and reopen the app. The window also provides **Open System Settings** whenever access is missing.

Monitoring works while other apps have focus. It uses a passive event tap for modifier changes only, does not record typed text, and does not intercept keyboard input. The **Play Beep** button works without permission. macOS may restrict monitoring during protected input, such as password entry.

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

`TalkToPromptApp.swift` defines the single-window lifecycle, `ContentView.swift` defines the UI and permission guidance, `ShiftMonitor.swift` manages permission and global modifier monitoring, and `BeepPlayer.swift` generates and plays the tones using AVFoundation. SwiftUI's `Window` scene automatically quits the app when its sole window closes.

During development, keep the bundle identifier and build location stable. macOS ties privacy grants to the app's identity; rebuilding an ad hoc signed app can require enabling access again. Use a consistent Apple development signing identity for more stable permission testing.
