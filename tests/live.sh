#!/bin/bash
# Live paste tests: drives the running Voci.app with a recorded clip and reads back each field.
# Usage: tests/live.sh [app ...]   (default: TextEdit Notes Safari "Google Chrome" "Brave Browser")
set -uo pipefail
cd "$(dirname "$0")/.."
LOG="$HOME/Library/Logs/Voci.log"
CLIP="$PWD/tests/audio/11.aiff"      # "Nu șterge nimic din folderul src fără să mă întrebi mai întâi."
EN="(Don't|Do not) delete anything from the src folder without asking me first\."
PAGE="http://127.0.0.1:8765/tests/page.html"
python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER=$!; trap 'kill $SERVER' EXIT; sleep 0.5
POST=.build/post
[ -x $POST ] || swiftc -O -o $POST - <<'EOF'
import Foundation
let a = CommandLine.arguments
DistributedNotificationCenter.default().postNotificationName(.init(a[1]), object: a.count > 2 ? a[2] : nil, userInfo: nil, deliverImmediately: true)
EOF
[ -f "$CLIP" ] || say -v Ioana -o "$CLIP" "Nu șterge nimic din folderul src fără să mă întrebi mai întâi."

keys() { osascript -e "tell application \"System Events\" to $1"; }
pass=0; fail=0

# setup <app> <text> <caret>: opens an editable field holding <text> with the cursor at <caret>.
setup() {
  local app=$1 text=$2 caret=$3
  case $app in
    TextEdit)
      osascript -e 'tell application "TextEdit" to activate' -e "tell application \"TextEdit\" to make new document with properties {text:\"$text\"}" >/dev/null
      sleep 0.5; keys 'key code 126 using command down'; for ((i = 0; i < caret; i++)); do keys 'key code 124'; done ;;
    Notes)
      osascript -e 'tell application "Notes" to activate' >/dev/null; sleep 0.5
      keys 'keystroke "n" using command down'; sleep 0.8
      [ -n "$text" ] && keys "keystroke \"$text\""
      keys 'key code 126 using command down'; for ((i = 0; i < caret; i++)); do keys 'key code 124'; done ;;
    *) # browsers: test page, $kind selects textarea or contenteditable
      local enc; enc=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$text")
      open -a "$app" "$PAGE?field=$kind&text=$enc&caret=$caret&n=$RANDOM"; sleep 2.5 ;;
  esac
}

# check <name> <regex>: injects the clip, waits for the paste, verifies field and clipboard.
check() {
  local name=$1 want=$2 before
  before=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  echo "CLIPBOARD-SENTINEL" | pbcopy
  $POST app.voci.inject "$CLIP"
  for i in $(seq 1 60); do
    sleep 1
    tail -n +$((before + 1)) "$LOG" | grep -qE "pasted=|error:" && break
  done
  sleep 1.2 # clipboard restore happens 0.6 s after paste
  local clip; clip=$(pbpaste)
  keys 'keystroke "a" using command down'; keys 'keystroke "c" using command down'; sleep 0.4
  local got; got=$(pbpaste | tr '\n' ' ' | sed 's/ *$//')
  if echo "$got" | grep -qE "^$want$" && [ "$clip" = "CLIPBOARD-SENTINEL" ]; then
    echo "PASS  $name"; pass=$((pass + 1))
  else
    echo "FAIL  $name  field=[$got] clipboard=[$clip]"; fail=$((fail + 1))
    tail -n +$((before + 1)) "$LOG" | sed 's/^/      log: /'
  fi
}

apps=("$@"); [ ${#apps[@]} -eq 0 ] && apps=(TextEdit Notes Safari "Google Chrome" "Brave Browser")
for app in "${apps[@]}"; do
  kinds=(ta); case $app in TextEdit|Notes) kinds=(-);; *) kinds=(ta ce);; esac
  for kind in "${kinds[@]}"; do
    tag="$app${kind/#-/}"; [ "$kind" != "-" ] && tag="$app/$kind"
    setup "$app" "" 0;                  check "$tag empty"  "$EN"
    setup "$app" "Hello there." 12;     check "$tag append" "Hello there\. $EN"
    setup "$app" "Start end" 6;         check "$tag middle" "Start $EN end"
  done
done
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
