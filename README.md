# TalkToPrompt

A native macOS menu bar app for dictating into the active app using your own OpenAI API key. It has no Dock icon. Click the microphone-and-cursor menu bar icon to open its compact settings popover; click outside to dismiss it without stopping keyboard monitoring. Use **Quit TalkToPrompt** in the footer to exit.

The 420-point-wide popover fits its content with equal 16-point outer padding and follows the system light or dark appearance. Its header, permission labels, API key, Launch at Login, and privacy disclosure use aligned icon and text columns. Each permission has a gear button that opens its specific System Settings pane. There is no separate Settings button. The API key supports **Enter**, **Change**, and a small clear control; changing a key still validates the replacement before storing it.

On first launch, the popover opens for setup. Later launches run in the menu bar; errors and permission/restart explanations reopen the popover as needed. Monitoring is owned by the app delegate rather than the popover, so dismissing settings does not interrupt capture or transcription. Key-entry sheets and alerts keep their host popover open until dismissed.

Hold **left Shift + right Shift** to start a session. Every connected screen shows the overlay, and the rising 440 → 880 Hz cue plays. Once microphone samples arrive, the center heading shows **Listening...**, with elapsed seconds on a separate, smaller, regular-weight gray line below. The counter updates as recording continues.

Release either Shift to stop and release the microphone, then send the recording to OpenAI for transcription using the app's Keychain API key. The overlay shows **Transcribing...** until the returned text is pasted into the currently active app using the clipboard helper. It then fades away over 222 ms and plays the falling exit cue. Further double-Shift presses and releases are ignored until the session has fully closed.

Without an API key, holding both Shifts shows **No OpenAI API key provided**, without accessing the microphone or sending a request. Releasing either Shift dismisses it. Enter a key in the popover to record on the next hold. If no speech is recognized, the overlay closes quietly without pasting or displaying an error. Request or paste failures close the overlay before displaying a human-readable modal error.

The full-screen panels use native backdrop blur with an 80%-opaque white tint, fading in and out over 222 ms. macOS controls the native blur radius; the animation changes its visible strength. No screen capture or Screen Recording permission is needed. Panels cover the menu bar and Dock, appear across Spaces and alongside full-screen apps, and do not take keyboard focus or intercept mouse clicks. Newly connected screens inherit the current status message.

Both cues last 222 ms with a raised-cosine volume envelope, `(1 - cos(2πt / 0.222)) / 2`: silence → peak at 111 ms → silence. Pitch changes linearly with continuous phase.

## Keyboard permissions

At startup, the app checks Input Monitoring and event-posting permission. If a missing permission has never been requested, it explains both permissions and offers an **Open System Settings** button for each missing permission, plus **Not Now**. Each Settings button requests access if missing and opens the corresponding macOS Settings pane; the app cannot grant permission itself. Declining a request leaves a reminder in the popover without repeatedly showing the startup explanation.

In **System Settings → Privacy & Security → Input Monitoring**, enable **TalkToPrompt**. The app rechecks when you return and periodically while running. If macOS asks you to quit and reopen the app, do so. If access is enabled but monitoring cannot start, quit and reopen the app. The gear beside Input Monitoring always opens its Settings pane.

Monitoring works while other apps have focus. It uses a passive event tap to watch Shift keys, does not record typed text, and does not intercept keyboard input. macOS may restrict monitoring during protected input, such as password entry.

Event-posting permission is shown under **System Settings → Privacy & Security → Accessibility**. Use **Open System Settings** beside Accessibility in the startup explanation, or use the Accessibility gear in the popover, to request access if missing and open Settings so you can enable **TalkToPrompt**. Its status is rechecked when you return and periodically while running. Follow any macOS quit-and-reopen instructions. This permission is used by the clipboard insertion helper. Recording needs Input Monitoring and Microphone permission; pasting the transcript also needs Accessibility permission. If you open Accessibility settings while access is missing, returning to TalkToPrompt shows an in-app **Restart** / **Not Now** prompt, even if macOS does not offer to restart. Choose Restart after enabling the toggle. The app stops the current audio session and launches a replacement instance before quitting; if launching fails, the current app stays open and displays an error.

## Clipboard text insertion

The session uses the clipboard helper to insert the returned transcript into the active app. `ClipboardTextInserter.swift` provides `try await inserter.insert(text)` for arbitrary Unicode or multiline text. It backs up clipboard contents (including available rich-text representations), writes the supplied text, waits **111 ms**, posts **⌘V**, waits another **111 ms**, and restores the backup. Its synthetic Paste shortcut uses Command alone, even if a physical Shift key is still held. Calls are serialized so repeated shortcuts do not corrupt the backup.

If another app or the user copies new content during the operation, the helper keeps that newer clipboard rather than overwriting it. It aborts before pasting if focus switches to another app, permission is revoked, or the clipboard changes. Cancellation restores clipboard contents still owned by the helper. A caller using it during app shutdown should also call `restorePendingClipboard()` before terminating.

The destination must have an editable field that accepts Paste. The delays allow time for the destination to read the clipboard; macOS does not confirm whether another app accepted the paste, and some apps may need a longer delay.

## Microphone recording

With an API key configured, pressing both Shift keys opens the overlay and starts microphone capture as quickly as the input device allows. The large black **Listening...** heading and smaller gray seconds counter appear after the first audio buffer arrives. Releasing either Shift removes the input tap before transcription starts. Capture also stops if monitoring stops, microphone access is revoked or disconnected, or the app quits.

The **Microphone** permission row sits after Accessibility and before OpenAI API Key. Its gear button requests access on first use and opens **Privacy & Security → Microphone**. The first recording also requests permission if necessary. During the system consent prompt the overlay is temporarily hidden for readability; recording starts only if both Shift keys are still held and the session has not been cancelled when access is granted.

`MicrophoneRecorder.swift` opens and releases the audio engine off the main thread and copies native PCM chunks into owned memory. `MicrophoneRecordingSession.swift` coordinates permission and capture. `VoiceSessionController.swift` owns session phases, counters, cancellation, and duplicate-trigger suppression. `RecordedAudioEncoding.swift` creates an in-memory WAV; `OpenAITranscriber.swift` uploads it to `POST https://api.openai.com/v1/audio/transcriptions` using `gpt-transcribe` and reads the JSON transcript. Requests use an ephemeral URLSession, a 60-second inactivity timeout and 120-second resource timeout. Audio files must be under 25 MB; longer recordings report an error instead of uploading.

The latest recording remains in RAM until the next recording or app exit. Audio is sent to OpenAI for transcription and is not written to a local audio file. The sandbox enables microphone input and outbound network connections. Tests use synthetic PCM, fake capture devices, fake credentials, and mocked HTTP transport; they do not record microphone audio or call the live API.

## OpenAI API key

The API key row shows **Not provided** or **Provided sk-...TqUA**, using only the key’s first three and last four characters. Missing or unreadable keys are indicated in red.

Choose **Enter** or **Change** to open a secure input dialog. **OK** first changes the popup to **Validating API key...** and sends one second of generated silence to the same OpenAI transcription endpoint and model used for recordings (a small API charge may apply). Only a successful, valid response allows saving; the silent test may return an empty transcript. The key is not stored during validation. Invalid keys, quota/billing failures, unavailable service, and network errors return to the input UI with a readable error so you can edit the key or retry. **Cancel** cancels validation and prevents saving even if a response arrives later. On success, the popup closes and stores the key in the macOS Keychain as a generic-password item with account **OPENAI_API_KEY** and the app’s bundle identifier as its service. **Cancel** closes the dialog without saving. The clear control deletes only that Keychain item. The key is loaded at startup and is never written to a preferences file or repository configuration.

## Menu bar readiness status

The transparent menu bar icon uses the same microphone-and-cursor artwork as the application icon. The microphone and cursor remain neutral, adapting automatically to the menu bar appearance. A small lower-right circle is green when Input Monitoring is working, Accessibility and Microphone permissions are granted, and an API key is provided and readable; otherwise the circle is red. Launch at Login does not affect readiness. Reference colors are green `#35C759` and red `#FF5C60`.

`MenuBarIcon.swift` crops the app-icon padding from the bundled transparent `MenuBarSymbols.png` and uses a neutral template image without adding a background. A separate colored indicator shows readiness. System Settings shortcuts dismiss the popover before opening their pane, including shortcuts in the permission explanation. The saved Finder application icon remains unchanged. `LSUIElement` and the accessory activation policy keep the app out of the Dock and app switcher, including while the popover or an API key sheet is open.

## Launch at login

The **Launch at Login** row appears immediately after OpenAI API Key. Its switch registers or unregisters the main application with macOS using `SMAppService.mainApp`. Enabling it launches TalkToPrompt when you sign in to your Mac, including after restarting. It starts menu bar monitoring without opening settings after first setup; microphone recording still requires holding both Shift keys.

The switch reflects the requested login setting; **Needs approval** or **Unavailable** appears below the label when attention is required. If approval is needed, the gear button opens Login Items so you can approve the app; the switch can also cancel the registration. The status refreshes when you return to the app. The setting is owned by macOS and survives app restarts; opening the app never enables it automatically. Keep the app at a stable location (for example, Applications) when enabling it. Registration failures display a readable error and retain the actual system state.

## App icon

`TalkToPrompt/TalkToPromptIcon.icon` is the app's layered Icon Composer document and is included in the app target's resources. Its solid white background is separate from the black microphone/cursor artwork in `Assets/Symbols.png` (rasterized from `Assets/Symbols.svg` to avoid stroke clipping in the native icon renderer); macOS supplies the outer mask and material. Edit the `.icon` document in Icon Composer, then rebuild normally. Xcode compiles the layered icon and generates a legacy `.icns` for older macOS versions.

## Run in Xcode

1. Open `TalkToPrompt.xcodeproj`.
2. Select the **TalkToPrompt** scheme and **My Mac** destination.
3. Press **⌘R**.

Requires macOS 14 or later and Xcode 26 or later. There are no external dependencies. Microphone recording requires permission in Privacy & Security → Microphone. The app runs exclusively in the menu bar.

For distribution, select your Apple development team in the target's **Signing & Capabilities** settings. Local development uses ad hoc signing and needs no team.

## Build from Terminal

```sh
make run    # Build and launch the app
make build  # Build only (also the default for `make`)
make test   # Run keyboard state, tone, and permission-flow tests
make clean  # Clean build products
```

Build and launch an optimized Release version with `make run CONFIGURATION=Release`.

`TalkToPromptApp.swift` owns the status item, popover, and persistent monitoring lifecycle; `ContentView.swift` wires settings and modal presentation to the models; `NativeCalmView.swift` defines the compact appearance-aware layout; `ShiftMonitor.swift` manages permission and global modifier monitoring; `BeepPlayer.swift` generates the tones; `ClipboardTextInserter.swift` handles clipboard-backed pasting; and `DesktopOverlayController.swift` owns the per-screen overlay panels.

During development, keep the bundle identifier and build location stable. macOS ties privacy grants to the app's identity; rebuilding an ad hoc signed app can require enabling access again. Use a consistent Apple development signing identity for more stable permission testing.
