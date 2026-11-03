# TalkToPrompt

A native macOS SwiftUI app with a single window and a centered **Play Beep** button. Pressing it plays a 440 Hz sine wave for one second. Pressing it again restarts the tone. Closing the window quits the app.

## Run in Xcode

1. Open `TalkToPrompt.xcodeproj`.
2. Select the **TalkToPrompt** scheme and **My Mac** destination.
3. Press **⌘R**.

Requires macOS 14 or later and Xcode 15 or later. There are no external dependencies, microphone permissions, or setup steps. The app uses normal macOS Dock and menu bar behavior.

For distribution, select your Apple development team in the target's **Signing & Capabilities** settings. Local development uses ad hoc signing and needs no team.

## Build from Terminal

```sh
make run    # Build and launch the app
make build  # Build only (also the default for `make`)
make clean  # Clean build products
```

Build and launch an optimized Release version with `make run CONFIGURATION=Release`.

`TalkToPromptApp.swift` defines the single-window lifecycle, `ContentView.swift` defines the UI, and `BeepPlayer.swift` generates and plays the tone using AVFoundation. SwiftUI's `Window` scene automatically quits the app when its sole window closes.
