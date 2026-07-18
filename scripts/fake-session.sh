#!/bin/bash
# Drive the menu bar app with fake contract state files across both agents.
# Run the app first: StatusBarApp/.build/debug/AgentStatusBar &
set -euo pipefail

BASE="${XDG_STATE_HOME:-$HOME/.local/state}"
CLAUDE_DIR="$BASE/claude-sessions"
AGY_DIR="$BASE/antigravity-sessions"
mkdir -p "$CLAUDE_DIR" "$AGY_DIR"

now() { python3 -c 'import time; print(time.time())'; }

write() { # write <dir> <id> <state> <since>
  cat > "$1/$2.json" <<EOF
{"version": 1, "session_id": "$2", "state": "$3", "since": $4,
 "cwd": "/tmp/fake-$2", "pid": $$, "updated_at": $(now)}
EOF
}

cleanup() { rm -f "$CLAUDE_DIR"/fake-*.json "$AGY_DIR"/fake-*.json; }
trap cleanup EXIT

echo "1/4: claude running x2, agy idle -> bar [play]2 [check]1; rows tagged claude/agy"
write "$CLAUDE_DIR" fake-a running "$(now)"
write "$CLAUDE_DIR" fake-b running "$(now)"
write "$AGY_DIR" fake-c idle "$(now)"
sleep 8

echo "2/4: agy idle past threshold -> expect blink + Tink sound"
write "$AGY_DIR" fake-c idle "$(python3 -c 'import time; print(time.time() - 300)')"
sleep 8

echo "3/4: mix -> claude permission(fake-a) + claude running(fake-b) + agy running(fake-c); bar [play]2 [hand]1"
write "$CLAUDE_DIR" fake-a permission "$(now)"
write "$AGY_DIR" fake-c running "$(now)"
sleep 8

echo "4/4: cleanup -> expect dimmed terminal glyph"
