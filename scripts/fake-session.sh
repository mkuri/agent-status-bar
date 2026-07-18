#!/bin/bash
# Drive the menu bar app with fake contract state files.
# Run the app first: StatusBarApp/.build/debug/AgentStatusBar &
set -euo pipefail

DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-sessions"
mkdir -p "$DIR"

now() { python3 -c 'import time; print(time.time())'; }

write() { # write <id> <state> <since>
  cat > "$DIR/$1.json" <<EOF
{"version": 1, "session_id": "$1", "state": "$2", "since": $3,
 "cwd": "/tmp/fake-$1", "pid": $$, "updated_at": $(now)}
EOF
}

cleanup() { rm -f "$DIR"/fake-*.json; }
trap cleanup EXIT

echo "1/4: two running, one permission -> expect  [play]2 [hand]1"
write fake-a running "$(now)"
write fake-b running "$(now)"
write fake-c permission "$(now)"
sleep 8

echo "2/4: permission past threshold -> expect blink + Glass sound"
write fake-c permission "$(python3 -c 'import time; print(time.time() - 300)')"
sleep 8

echo "3/4: all idle -> expect  [check]3, blinking stops"
write fake-a idle "$(now)"
write fake-b idle "$(now)"
write fake-c idle "$(now)"
sleep 8

echo "4/4: cleanup -> expect dimmed terminal glyph"
