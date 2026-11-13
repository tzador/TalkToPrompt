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

The overlay shows elapsed seconds, buffer usage, and estimated recording time remaining. Its single circle responds to your current volume and turns red after five minutes or at 20 MB, whichever comes first. Recording automatically stops and transcribes after six minutes or at 24 MB. Audio stays in memory as 16 kHz, 16-bit mono PCM and is uploaded as WAV.

Dark translucent captions show elapsed time above “Listening” and remaining time below it. The desktop dims outside the translucent circle. During transcription, the circle gently expands and contracts, then collapses to zero when the overlay closes.

Use the menu bar icon to change your API key, choose a language hint, or enable **Launch at Login**. Green means ready; red means setup needs attention.
