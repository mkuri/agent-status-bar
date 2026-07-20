#!/usr/bin/env bash
# Interactive, idempotent installer for the session-state-recorder hooks.
# Registers the Claude Code, Antigravity (agy), and/or Codex producer into the
# agent's hook config. Safe to re-run. Stdlib Python only; no jq dependency.
#
# Symlinked (dotfiles-managed) config is supported: the installer resolves the
# real target and, with your confirmation, edits that file — so you can review
# and commit it in the repo that owns it.
set -euo pipefail

RECORDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer a $HOME-relative command when the recorder lives under $HOME: it is
# shorter, leaks no username, and works on any machine with the same layout.
# The literal $HOME is expanded by the shell that runs the hook. Fall back to
# the absolute path for a clone that lives outside $HOME.
case "$RECORDER_DIR" in
  "$HOME"/*) HOOK_BASE="\$HOME${RECORDER_DIR#"$HOME"}" ;;
  *)         HOOK_BASE="$RECORDER_DIR" ;;
esac
CLAUDE_HOOK="$HOOK_BASE/record-session-state.py"
AGY_HOOK="$HOOK_BASE/record-antigravity-session-state.py"
CODEX_HOOK="$HOOK_BASE/record-codex-session-state.py"

confirm() {
  # confirm "<question>" <default: Y|N> -> returns 0 for yes
  local question="$1" default="$2" hint reply
  if [ "$default" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "$question $hint " reply || reply=""
  reply="${reply:-$default}"
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

resolve_config_target() {
  # resolve_config_target <path> <label>
  # Echo the path the caller should edit. If <path> is a symlink (typical of a
  # dotfiles-managed config), resolve it to the real target and, after an
  # explicit confirmation, echo that target instead. Diagnostics go to stderr so
  # the echoed path is the only thing on stdout. Returns 1 (echoing nothing)
  # when the user declines or the symlink is broken, so the caller skips.
  local path="$1" label="$2" target
  if [ -L "$path" ]; then
    target="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path")"
    if [ ! -e "$target" ]; then
      echo "!! $path is a symlink to a missing target ($target). Skipping $label." >&2
      return 1
    fi
    echo "!! $path is a symlink -> $target (looks dotfiles-managed)." >&2
    echo "   I can edit the real file; review & commit it in that repo afterward." >&2
    if confirm "Edit the real file $target?" "N"; then
      echo "$target"
      return 0
    fi
    echo "   Skipped $label. Add the hooks manually (see README) or edit your dotfiles." >&2
    return 1
  fi
  echo "$path"
}

install_claude() {
  local orig="$HOME/.claude/settings.json" settings
  # `|| return 0`: a declined/skipped resolve returns 0 so `set -e` does not
  # abort the whole installer (it must fall through to the Antigravity prompt).
  settings="$(resolve_config_target "$orig" "Claude Code")" || return 0
  mkdir -p "$(dirname "$settings")"
  local tmp="$settings.tmp.$$" result
  result="$(python3 - "$settings" "$CLAUDE_HOOK" "$tmp" <<'PY'
import json, os, sys
settings_path, hook, out = sys.argv[1], sys.argv[2], sys.argv[3]
cmd = 'python3 "%s"' % hook
# event -> matcher (None = no matcher). Parity with the tested config.
events = [
    ("SessionStart", None), ("UserPromptSubmit", None), ("PermissionRequest", None),
    ("PostToolUse", None), ("PostToolUseFailure", None), ("Stop", None),
    ("StopFailure", None), ("Notification", "idle_prompt"), ("SessionEnd", None),
]
data = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        data = json.load(f)
before = json.dumps(data, sort_keys=True)
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
if json.dumps(data, sort_keys=True) == before:
    print("unchanged")
else:
    with open(out, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("changed")
PY
)"
  if [ "$result" = "changed" ]; then
    # Back up a plain real file before replacing it; skip the .bak for a
    # symlink-resolved target (dotfiles-managed — its history is in that repo,
    # and a stray .bak would litter it).
    if [ ! -L "$orig" ] && [ -f "$settings" ]; then cp "$settings" "$settings.bak.$(date +%s)"; fi
    mv "$tmp" "$settings"
    echo "-> Claude hook registered in $settings"
  else
    rm -f "$tmp"
    echo "-> Claude hook already registered in $settings (no change)"
  fi
}

install_agy() {
  local orig="$HOME/.gemini/config/hooks.json" cfg
  cfg="$(resolve_config_target "$orig" "Antigravity")" || return 0
  mkdir -p "$(dirname "$cfg")"
  local tmp="$cfg.tmp.$$" result
  result="$(python3 - "$cfg" "$AGY_HOOK" "$tmp" <<'PY'
import json, os, sys
cfg_path, hook, out = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        data = json.load(f)
before = json.dumps(data, sort_keys=True)
group = data.setdefault("record-session-state", {})
for event in ("PreInvocation", "Stop"):
    arr = group.setdefault(event, [])
    cmd = 'python3 "%s" %s' % (hook, event)
    if any(h.get("command") == cmd for h in arr):
        continue
    arr.append({"type": "command", "command": cmd})
if json.dumps(data, sort_keys=True) == before:
    print("unchanged")
else:
    with open(out, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("changed")
PY
)"
  if [ "$result" = "changed" ]; then
    if [ ! -L "$orig" ] && [ -f "$cfg" ]; then cp "$cfg" "$cfg.bak.$(date +%s)"; fi
    mv "$tmp" "$cfg"
    echo "-> Antigravity hook registered in $cfg"
  else
    rm -f "$tmp"
    echo "-> Antigravity hook already registered in $cfg (no change)"
  fi
}

install_codex() {
  local orig="$HOME/.codex/hooks.json" cfg
  cfg="$(resolve_config_target "$orig" "Codex")" || return 0
  mkdir -p "$(dirname "$cfg")"
  local tmp="$cfg.tmp.$$" result
  result="$(python3 - "$cfg" "$CODEX_HOOK" "$tmp" <<'PY'
import json, os, sys
cfg_path, hook, out = sys.argv[1], sys.argv[2], sys.argv[3]
cmd = 'python3 "%s"' % hook
events = ("SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop")
data = {}
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        data = json.load(f)
before = json.dumps(data, sort_keys=True)
hooks = data.setdefault("hooks", {})
for event in events:
    arr = hooks.setdefault(event, [])
    already = any(
        any(h.get("command") == cmd for h in entry.get("hooks", []))
        for entry in arr
    )
    if already:
        continue
    arr.append({"hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
if json.dumps(data, sort_keys=True) == before:
    print("unchanged")
else:
    with open(out, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("changed")
PY
)"
  if [ "$result" = "changed" ]; then
    if [ ! -L "$orig" ] && [ -f "$cfg" ]; then cp "$cfg" "$cfg.bak.$(date +%s)"; fi
    mv "$tmp" "$cfg"
    echo "-> Codex hook registered in $cfg"
  else
    rm -f "$tmp"
    echo "-> Codex hook already registered in $cfg (no change)"
  fi
}

echo "session-state-recorder installer"
echo "Recorder: $RECORDER_DIR"
echo

claude_default=N; [ -d "$HOME/.claude" ] && claude_default=Y
agy_default=N;    [ -d "$HOME/.gemini" ] && agy_default=Y
codex_default=N;  [ -d "$HOME/.codex" ] && codex_default=Y

if confirm "Register the Claude Code hook?" "$claude_default"; then install_claude; fi
if confirm "Register the Antigravity (agy) hook?" "$agy_default"; then install_agy; fi
if confirm "Register the Codex hook?" "$codex_default"; then install_codex; fi

echo
echo "Done. Session state files will appear under:"
echo "  \${XDG_STATE_HOME:-\$HOME/.local/state}/claude-sessions/"
echo "  \${XDG_STATE_HOME:-\$HOME/.local/state}/antigravity-sessions/"
echo "  \${XDG_STATE_HOME:-\$HOME/.local/state}/codex-sessions/"
echo "Restart your agent sessions for the hooks to take effect."
