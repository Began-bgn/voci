# Voci

Speak Romanian, get polished English pasted at your cursor. Mac menu-bar app (~80 MB RAM); speech recognition and translation run on Groq's free tier.

**Use:** press `⌃⌥Space`, speak, then press it again (or pause 3 s). The English text is inserted at the cursor of whatever text field is focused. It is never sent. `Esc` cancels.

## Setup

1. Create a free key at [console.groq.com/keys](https://console.groq.com/keys) (email sign-up, no card).
2. Build and open:
   ```bash
   scripts/build.sh    # builds, signs and installs ~/Applications/Voci.app
   open ~/Applications/Voci.app
   ```
3. Paste the key in Settings (stored in the macOS Keychain). Grant **Microphone** (prompted) and **Accessibility** (System Settings › Privacy & Security › Accessibility).

Signing uses your Xcode "Apple Development" identity so permissions survive rebuilds.

## How it works

| Step | Tool |
|---|---|
| Hotkey | Carbon `RegisterEventHotKey` |
| Record + silence stop | `AVAudioEngine`, adaptive noise floor, trimmed to speech |
| Romanian → text | Groq `whisper-large-v3` |
| Text → polished English | Groq `openai/gpt-oss-120b` (falls back to `qwen/qwen3.8-27b` on rate limit), few-shot prompt |
| Paste | Accessibility for smart spacing, clipboard + ⌘V, clipboard restored |

Free tier (per day): 1,000 translations per model, 2,000 transcriptions. A failed recording is kept; use **Retry last recording** in the menu.

Menu bar: history (last 20, local only), microphone, sound cues, settings (API key, shortcut, silence timeout, model, launch at login).

## Testing

```bash
B=~/Applications/Voci.app/Contents/MacOS/Voci
$B --pipeline file.aiff        # transcribe + translate a file
$B --translate "text"          # translate only; --model to compare
$B --models                    # models your key can use
tests/live.sh                  # paste tests in TextEdit, Notes, Safari, Chrome, Brave
```

Log: `~/Library/Logs/Voci.log` (events only, no transcript text).
