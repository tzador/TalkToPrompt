# TalkToPrompt

Speak into any Mac app.

## Install

Requires **macOS 14+** and **Xcode 26+** to install from source.

```sh
git clone https://github.com/tzador/TalkToPrompt.git
cd TalkToPrompt
make install
open /Applications/TalkToPrompt.app
```

Follow the setup wizard to grant Accessibility, Input Monitoring, and Microphone permissions, then enter your [OpenAI API key](https://platform.openai.com/api-keys). Restart when prompted. OpenAI API usage is billed separately.

## Use

1. Click a text field in any app.
2. Hold **left Shift + right Shift** and speak.
3. Release either Shift. Your words are transcribed and inserted automatically.

Click the menu bar icon to change your API key, enable **Launch at Login**, or quit. Its indicator is green when ready and red when setup needs attention.

## Development

Requires full Xcode 26+ with its command-line tools selected. Builds use the Debug configuration by default and store Xcode build data under `build/`.

| Command | Behavior |
| --- | --- |
| `make` or `make build` | Check Xcode tool availability and build `build/Build/Products/Debug/TalkToPrompt.app`. Does not install or launch it. |
| `make run` | Build, stop running TalkToPrompt processes, copy the app to `/Applications/TalkToPrompt.app`, and launch that installed copy. |
| `make install` | Build Release by default and copy the app to `/Applications/TalkToPrompt.app`. Does not launch it. |
| `make test` | Build and run the macOS test suite using the selected configuration. |
| `make check` | Check that Xcode command-line tools are available and configured. |
| `make clean` | Clean Xcode build products for the selected configuration. |
| `make zip` | Archive Git-tracked files from the working tree into `build/TalkToPrompt.zip`. This is a source archive, not an app bundle. |

Override the configuration on the command line, for example:

```sh
make run CONFIGURATION=Release
```

The build and test targets use the first valid Apple Development signing identity reported by the local keychain. If none is available, they fall back to ad hoc signing. Override the identity with a certificate name or hash, or explicitly select ad hoc signing:

```sh
make run SIGNING_IDENTITY="certificate name or hash"
make run SIGNING_IDENTITY=-
```

Use `make run` to keep the launched app at the same installed path. Certificate-backed signing keeps its code identity stable across rebuilds. With ad hoc signing, a rebuild can invalidate macOS permission grants; you may need to remove the old TalkToPrompt entry from Accessibility and Input Monitoring and add `/Applications/TalkToPrompt.app` again.
