#!/usr/bin/env bash
# Interactive, idempotent installer for the session-state-recorder hooks.
# Registers the Claude Code and/or Antigravity (agy) producer into the agent's
# hook config. Safe to re-run. Stdlib Python only; no jq dependency.
set -euo pipefail

RECORDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOOK="$RECORDER_DIR/record-session-state.py"
AGY_HOOK="$RECORDER_DIR/record-antigravity-session-state.py"

confirm() {
  # confirm "<question>" <default: Y|N> -> returns 0 for yes
  local question="$1" default="$2" hint reply
  if [ "$default" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "$question $hint " reply || reply=""
  reply="${reply:-$default}"
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

install_claude() {
  local settings="$HOME/.claude/settings.json"
  if [ -L "$settings" ]; then
    echo "!! $settings is a symlink (looks dotfiles-managed)."
    echo "   Edit your dotfiles directly instead. Skipping Claude registration."
    return
  fi
  mkdir -p "$(dirname "$settings")"
  [ -f "$settings" ] || echo '{}' > "$settings"
  cp "$settings" "$settings.bak.$(date +%s)"
  python3 - "$settings" "$CLAUDE_HOOK" <<'PY'
import json, sys
settings_path, hook = sys.argv[1], sys.argv[2]
cmd = 'python3 "%s"' % hook
# event -> matcher (None = no matcher). Parity with the tested config.
events = [
    ("SessionStart", None), ("UserPromptSubmit", None), ("PermissionRequest", None),
    ("PostToolUse", None), ("PostToolUseFailure", None), ("Stop", None),
    ("StopFailure", None), ("Notification", "idle_prompt"), ("SessionEnd", None),
]
with open(settings_path) as f:
    data = json.load(f)
hooks = data.setdefault("hooks", {})
for event, matcher in events:
    arr = hooks.setdefault(event, [])
    already = any(
        any(h.get("command") == cmd for h in entry.get("hooks", []))
        for entry in arr
    )
    if already:
        continue
    entry = {"hooks": [{"type": "command", "command": cmd, "timeout": 5}]}
    if matcher:
        entry["matcher"] = matcher
    arr.append(entry)
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  echo "-> Claude hook registered in $settings"
}

install_agy() {
  local cfg="$HOME/.gemini/config/hooks.json"
  mkdir -p "$(dirname "$cfg")"
  [ -f "$cfg" ] && cp "$cfg" "$cfg.bak.$(date +%s)"
  python3 - "$cfg" "$AGY_HOOK" <<'PY'
import json, os, sys
cfg_path, hook = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        data = json.load(f)
group = data.setdefault("record-session-state", {})
for event in ("PreInvocation", "Stop"):
    arr = group.setdefault(event, [])
    cmd = 'python3 "%s" %s' % (hook, event)
    if any(h.get("command") == cmd for h in arr):
        continue
    arr.append({"type": "command", "command": cmd})
with open(cfg_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  echo "-> Antigravity hook registered in $cfg"
}

echo "session-state-recorder installer"
echo "Recorder: $RECORDER_DIR"
echo

claude_default=N; [ -d "$HOME/.claude" ] && claude_default=Y
agy_default=N;    [ -d "$HOME/.gemini" ] && agy_default=Y

if confirm "Register the Claude Code hook?" "$claude_default"; then install_claude; fi
if confirm "Register the Antigravity (agy) hook?" "$agy_default"; then install_agy; fi

echo
echo "Done. Session state files will appear under:"
echo "  \${XDG_STATE_HOME:-\$HOME/.local/state}/claude-sessions/"
echo "  \${XDG_STATE_HOME:-\$HOME/.local/state}/antigravity-sessions/"
echo "Restart your agent sessions for the hooks to take effect."
