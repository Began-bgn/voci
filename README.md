# Voci

Speak Romanian, get polished English pasted at your cursor. Mac menu-bar app, fully local and free.

**Use:** press `⌃⌥Space`, speak, then press it again (or pause 3 s). The English text is inserted at the cursor of whatever text field is focused. It is never sent. `Esc` cancels.

## Setup

```bash
scripts/setup.sh    # Ollama + qwen3:14b + Whisper models + whisper.cpp framework (~11 GB, once)
scripts/build.sh    # builds, signs and installs ~/Applications/Voci.app
open ~/Applications/Voci.app
```

Grant **Microphone** (prompted) and **Accessibility** (System Settings › Privacy & Security › Accessibility). Signing uses your Xcode "Apple Development" identity so permissions survive rebuilds.

## How it works

| Step | Tool |
|---|---|
| Hotkey | Carbon `RegisterEventHotKey` |
| Record + silence stop | `AVAudioEngine`, adaptive noise floor |
| Romanian → text | whisper.cpp `large-v3-turbo` on Metal, Silero VAD |
| Text → polished English | Ollama `qwen3:14b`, few-shot prompt, temperature 0 |
| Paste | Accessibility for smart spacing, clipboard + ⌘V, clipboard restored |

Menu bar: history (last 20, local only), microphone, sound cues, settings (shortcut, silence timeout, model, launch at login).

## Testing

```bash
~/Applications/Voci.app/Contents/MacOS/Voci --pipeline file.aiff   # transcribe + translate a file
~/Applications/Voci.app/Contents/MacOS/Voci --translate "text"     # translate only; --model to compare
tests/live.sh                                                         # paste tests in TextEdit, Notes, Safari, Chrome, Brave
```

Log: `~/Library/Logs/Voci.log` (events only, no transcript text).
