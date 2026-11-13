# TalkToPrompt

Speak into any Mac app.

## Install

Requires **macOS 14+**, **full Xcode 26+**, and an [OpenAI API key](https://platform.openai.com/api-keys).

```sh
curl -fsSL https://raw.githubusercontent.com/tzador/TalkToPrompt/main/install.sh | bash
```

Builds from source, installs to `/Applications`, and launches. If Xcode needs setup, follow the printed instructions and retry. Run the same command to update.

Follow the setup wizard to grant permissions and enter your API key. OpenAI API usage is billed separately. After updates, you may need to grant permissions again.

## Use

1. Click a text field in any app.
2. Hold **left Shift + right Shift** and speak.
3. Release either Shift to transcribe and insert your words.

Press **Escape** at any time to cancel recording or transcription. The overlay fades and collapses as it closes.

The overlay shows elapsed recording time as `MM:SS` below “Listening”. Its single circle responds to your current volume and turns red after five minutes or at 20 MB, whichever comes first. Recording automatically stops and transcribes after six minutes or at 24 MB. Audio stays in memory as 16 kHz, 16-bit mono PCM and is uploaded as WAV.

Status captions use the system font, with gray text and a smoothly fading black letter highlight. The elapsed timer is monospaced and black. The desktop dims outside the circle, which has 90% opacity and a native background blur clipped to its shape. During transcription, the circle gently expands and contracts, then collapses to zero when the overlay closes.

Use the menu bar icon to change your API key, choose a language hint, or enable **Launch at Login**. A filled status indicator means ready; an outline means setup needs attention. The menu uses a monochrome palette with a green/red readiness badge and a red accent for Quit.
