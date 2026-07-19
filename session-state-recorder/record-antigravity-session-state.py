#!/usr/bin/env python3
"""Record Antigravity CLI (`agy`) session state for status display consumers.

Registered as an antigravity lifecycle hook (hooks.json). Reads one hook event
JSON from stdin, receives the event name as argv[1], and maintains one state
file per session at $XDG_STATE_HOME/antigravity-sessions/<id>.json via the
shared session_state helper. The schema is the same versioned contract the
Claude producer writes, consumed by display tools such as agent-status-bar.

Only PreInvocation -> running and Stop -> idle are handled. PostToolUse is
deliberately NOT hooked: live testing showed a trailing PostToolUse fires
AFTER Stop for a turn, which would reset the state back to running and the
session would never settle to idle.

Antigravity requires every hook to emit a JSON object on stdout; this monitor
always prints `{}` and never alters the agent's behavior (it does not hook
PreToolUse). Must never break or slow `agy`: always exits 0.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import session_state

EVENT_STATES = {
    "PreInvocation": "running",
    "Stop": "idle",
}


def default_state_dir():
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "antigravity-sessions"


def handle_event(event, payload, state_dir, now, pid):
    new_state = EVENT_STATES.get(event)
    if new_state is None:
        return
    session_id = payload.get("conversationId", "")
    workspaces = payload.get("workspacePaths")
    cwd = workspaces[0] if isinstance(workspaces, list) and workspaces else ""
    session_state.write_state(state_dir, session_id, new_state, cwd, pid, now)


def main():
    try:
        event = sys.argv[1] if len(sys.argv) > 1 else ""
        payload = json.load(sys.stdin)
        handle_event(event, payload, default_state_dir(), time.time(),
                     session_state.resolve_agent_pid(os.getppid()))
    except Exception:
        pass
    finally:
        sys.stdout.write("{}")


if __name__ == "__main__":
    main()
