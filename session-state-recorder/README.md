# session-state-recorder

The **producer** side of agent-status-bar: hook scripts that record each agent
session's state into a versioned JSON state-file contract. Display tools (the
`StatusBarApp/` menu bar app, or any other UI) are **consumers** that read those
files. This directory is the single source of truth for the producer; stdlib
Python only, no third-party dependencies.

## What it writes

One JSON file per session under an agent-specific state directory:

- Claude Code: `${XDG_STATE_HOME:-~/.local/state}/claude-sessions/<session_id>.json`
- Antigravity: `${XDG_STATE_HOME:-~/.local/state}/antigravity-sessions/<conversationId>.json`

Each file: `{version, session_id, state, since, cwd, pid, updated_at}`
(`state` is `running` / `idle` / `permission`). Schema details:
`../docs/superpowers/specs/2026-07-18-agent-status-bar-design.md`.

## Install (interactive)

```
./setup.sh
```

It asks whether to register the Claude Code hook and the Antigravity hook
(defaults inferred from `~/.claude` / `~/.gemini`), then merges the needed hook
entries into `~/.claude/settings.json` and/or `~/.gemini/config/hooks.json`.
It is idempotent (re-running makes no change and writes no backup). A plain
config file is backed up before editing. If your config is a symlink (e.g.
dotfiles-managed), it resolves the real target, shows it, and — only after you
confirm — edits that file in place (no `.bak` littering your repo; its version
history is your backup); review and commit it in the repo that owns it afterward.

Restart your agent sessions afterward for the hooks to take effect.

If you later move the clone, re-run `./setup.sh`; the command paths embed this
directory's absolute path, so the old entry (now pointing at a missing file) is
not auto-removed — delete the stale hook entry from your config.

## Install (manual)

If you prefer editing config by hand, add the recorder command under
`~/.claude/settings.json`'s `hooks` object for each of these events —
`SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`,
`PostToolUseFailure`, `Stop`, `StopFailure`, `SessionEnd` (no matcher), and
`Notification` (with `"matcher": "idle_prompt"`). The shape is:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"/absolute/path/to/session-state-recorder/record-session-state.py\"",
            "timeout": 5
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"/absolute/path/to/session-state-recorder/record-session-state.py\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Use `/absolute/path/to/session-state-recorder` = wherever you cloned this repo.

For Antigravity, add to `~/.gemini/config/hooks.json`:

```json
{
  "record-session-state": {
    "PreInvocation": [
      { "type": "command", "command": "python3 \"/absolute/path/to/session-state-recorder/record-antigravity-session-state.py\" PreInvocation" }
    ],
    "Stop": [
      { "type": "command", "command": "python3 \"/absolute/path/to/session-state-recorder/record-antigravity-session-state.py\" Stop" }
    ]
  }
}
```

## Test

```
for t in tests/test_*.py; do python3 "$t"; done
```
