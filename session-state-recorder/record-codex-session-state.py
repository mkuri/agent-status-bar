#!/usr/bin/env python3
"""Record Codex session state for status display consumers.

Registered as a Codex lifecycle hook. Reads one hook event JSON from stdin and
maintains one state file per session at
$XDG_STATE_HOME/codex-sessions/<session_id>.json (default
~/.local/state/codex-sessions/), via the shared session_state helper. The schema
is the same versioned contract used by the other producers in this directory.

Must never break or slow Codex: always exits 0 and writes nothing to stdout.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import session_state

EVENT_STATES = {
    "SessionStart": "idle",
    "UserPromptSubmit": "running",
    "PermissionRequest": "permission",
    "PostToolUse": "running",
    "Stop": "idle",
}


def default_state_dir():
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "codex-sessions"


def handle_event(payload, state_dir, now, pid):
    new_state = EVENT_STATES.get(payload.get("hook_event_name"))
    if new_state is None:
        return
    session_state.write_state(
        state_dir, payload.get("session_id", ""), new_state,
        payload.get("cwd") or "", pid, now,
    )


def main():
    try:
        payload = json.load(sys.stdin)
        handle_event(payload, default_state_dir(), time.time(),
                     session_state.resolve_agent_pid(os.getppid()))
    except Exception:
        pass


if __name__ == "__main__":
    main()
