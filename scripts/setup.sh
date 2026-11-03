#!/bin/bash
# One-time setup: Ollama + translation model + Whisper models. Safe to re-run.
set -euo pipefail
MODELS="$HOME/Library/Application Support/Voci/models"
mkdir -p "$MODELS"

command -v ollama >/dev/null || brew install ollama
brew services start ollama >/dev/null
until curl -s http://127.0.0.1:11434 >/dev/null; do sleep 1; done
ollama pull qwen3:14b

fetch() { [ -f "$MODELS/$1" ] || { curl -fL -o "$MODELS/$1.part" "$2" && mv "$MODELS/$1.part" "$MODELS/$1"; }; }
fetch ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
fetch ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

# whisper.cpp framework used by the Swift build
cd "$(dirname "$0")/.."
if [ ! -d Vendor/build-apple/whisper.xcframework ]; then
  mkdir -p Vendor && curl -fL -o Vendor/whisper.zip https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip
  (cd Vendor && unzip -q whisper.zip && rm whisper.zip)
fi
echo "Setup done."
