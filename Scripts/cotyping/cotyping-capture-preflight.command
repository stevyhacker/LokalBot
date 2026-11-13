#!/bin/bash
# Pre-flights every permission the cotyping capture needs, one dialog at a time.
# Click ALLOW on each macOS prompt that appears.
echo "== 1/3 Automation: Terminal -> TextEdit (click Allow if prompted)"
if osascript -e 'with timeout of 3600 seconds' \
          -e 'tell application "TextEdit"' \
          -e 'activate' \
          -e 'make new document' \
          -e 'set text of front document to "permission probe"' \
          -e 'close front document saving no' \
          -e 'end tell' \
          -e 'end timeout'; then
  echo "   OK: TextEdit automation"; automation_ok=1
else
  echo "   FAILED: TextEdit automation"; automation_ok=0
fi

echo "== 2/3 Automation + Accessibility: Terminal -> System Events keystrokes"
osascript -e 'with timeout of 3600 seconds' \
          -e 'tell application "TextEdit"' \
          -e 'activate' \
          -e 'make new document' \
          -e 'end tell' \
          -e 'delay 0.5' \
          -e 'tell application "System Events" to tell process "TextEdit"' \
          -e 'set frontmost to true' \
          -e 'keystroke "ping"' \
          -e 'end tell' \
          -e 'delay 0.5' \
          -e 'end timeout'
doc=$(osascript -e 'tell application "TextEdit" to get text of front document' 2>/dev/null)
osascript -e 'tell application "TextEdit" to close front document saving no' >/dev/null 2>&1
if [ "$doc" = "ping" ]; then echo "   OK: keystrokes land"; keystrokes_ok=1; else echo "   FAILED: keystrokes (doc=[$doc])"; keystrokes_ok=0; fi

echo "== 3/3 Screen Recording: screencapture (click Allow / grant if prompted)"
screencapture -x -R 0,0,80,60 /tmp/preflight-shot.png 2>/dev/null
[ -s /tmp/preflight-shot.png ] && echo "   OK: screencapture" || echo "   WARN: screenshots unavailable (text capture still works)"
rm -f /tmp/preflight-shot.png

echo
if [ "$automation_ok" = 1 ] && [ "$keystrokes_ok" = 1 ]; then
  echo "RESULT: all capture permissions OK — starting the full capture (about 10 minutes, hands off keyboard)."
  sleep 3
  exec "$(dirname "$0")/run-cotyping-side-by-side.command"
fi
echo "RESULT: a permission is still missing. Fix in System Settings -> Privacy & Security"
echo "  - Automation -> Terminal -> enable TextEdit and System Events"
echo "  - Accessibility -> enable Terminal"
echo "then re-run this script."
