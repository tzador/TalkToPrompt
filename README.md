# TalkToPrompt

Speak into any Mac app, with optional translation into another language.

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

## Translate

Use the same Shift shortcut to say a command **by itself**:

- **“Translate to Spanish”** — translate future dictation into Spanish. Use other English language names, such as Greek, Persian, or Ukrainian, to choose another target.
- **“Don't translate”**, **“No translation”**, **“Translation off”**, or **“Translation none”** — turn translation off and keep your original spoken language.

After choosing a target, speak in any language and the translated text will be inserted. Commands aren't pasted. Your language choice is remembered until you change it, including after restarting the app.
