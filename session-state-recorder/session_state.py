"""Shared state-file helpers for agent session recorders.

Consumed by the Claude Code and Antigravity CLI hook producers. Maintains one
JSON state file per session under an agent-specific state directory, following
the versioned contract read by display tools such as agent-status-bar. Stdlib
only; every function is best-effort and must never raise into the calling hook.
"""
import json
import os
import subprocess
import tempfile

STATE_VERSION = 1
SHELLS = {"sh", "bash", "zsh", "dash", "fish"}


def _unsafe(session_id):
    return not session_id or "/" in session_id or session_id.startswith(".")


def resolve_agent_pid(start_pid):
    """Walk up past any shell wrapper to the owning agent process.

    Hook commands may run via `sh -c ...`; the shell usually execs a single
    command (making our parent the agent process directly), but that is not
    guaranteed, so skip shell ancestors explicitly.
    """
    pid = start_pid
    for _ in range(5):
        try:
            out = subprocess.run(
                ["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                capture_output=True, text=True, timeout=1, check=True,
            ).stdout.strip().split(None, 1)
        except (subprocess.SubprocessError, OSError, ValueError):
            return pid
        if len(out) < 2 or os.path.basename(out[1].strip()) not in SHELLS:
            return pid
        try:
            pid = int(out[0])
        except ValueError:
            return pid
    return pid


def write_state(state_dir, session_id, state, cwd, pid, now):
    """Atomically write the session's state file, preserving `since`.

    `since` carries over from an existing file when the state is unchanged, so
    elapsed time in a state stays meaningful. An empty `cwd` falls back to the
    previous file's value. Invalid session ids are ignored.
    """
    if _unsafe(session_id):
        return
    path = state_dir / f"{session_id}.json"
    prev = {}
    try:
        prev = json.loads(path.read_text())
    except (OSError, ValueError):
        pass
    same_state = prev.get("state") == state and "since" in prev
    record = {
        "version": STATE_VERSION,
        "session_id": session_id,
        "state": state,
        "since": prev["since"] if same_state else now,
        "cwd": cwd or prev.get("cwd", ""),
        "pid": pid,
        "updated_at": now,
    }
    state_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=state_dir, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(record, f)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def delete_state(state_dir, session_id):
    """Remove a session's state file if present; ignore if already gone."""
    if _unsafe(session_id):
        return
    try:
        (state_dir / f"{session_id}.json").unlink()
    except OSError:
        pass
