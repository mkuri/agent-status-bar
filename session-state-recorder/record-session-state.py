#!/usr/bin/env python3
"""Record Claude Code session state for status display consumers.

Registered as a Claude Code hook for lifecycle events. Reads one hook event
JSON from stdin and maintains one state file per session at
$XDG_STATE_HOME/claude-sessions/<session_id>.json (default
~/.local/state/claude-sessions/), via the shared session_state helper. The
schema is a versioned contract consumed by display tools such as
agent-status-bar.

Must never break or slow Claude Code: always exits 0, writes nothing to stdout.
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
    "PostToolUseFailure": "running",
    "Stop": "idle",
    "StopFailure": "idle",
    "Notification": "idle",
}


def default_state_dir():
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "claude-sessions"


def handle_event(payload, state_dir, now, pid):
    session_id = payload.get("session_id", "")
    event = payload.get("hook_event_name")
    if event == "SessionEnd":
        session_state.delete_state(state_dir, session_id)
        return
    new_state = EVENT_STATES.get(event)
    if new_state is None:
        return
    session_state.write_state(state_dir, session_id, new_state,
                              payload.get("cwd") or "", pid, now)


def main():
    try:
        payload = json.load(sys.stdin)
        handle_event(payload, default_state_dir(), time.time(),
                     session_state.resolve_agent_pid(os.getppid()))
    except Exception:
        pass


if __name__ == "__main__":
    main()
