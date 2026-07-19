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
It is idempotent (safe to re-run), backs up any file it edits, and refuses to
touch a symlinked `settings.json` (e.g. a dotfiles-managed one).

Restart your agent sessions afterward for the hooks to take effect.

## Install (manual)

If you prefer editing config by hand, add an entry like this to
`~/.claude/settings.json` for each of the events `SessionStart`,
`UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `PostToolUseFailure`,
`Stop`, `StopFailure`, `Notification` (with `"matcher": "idle_prompt"`), and
`SessionEnd`:

```json
{
  "hooks": [
    {
      "type": "command",
      "command": "python3 \"/absolute/path/to/session-state-recorder/record-session-state.py\"",
      "timeout": 5
    }
  ]
}
```

For Antigravity, add to `~/.gemini/config/hooks.json` a `PreInvocation` and a
`Stop` entry whose command is
`python3 "/absolute/path/to/session-state-recorder/record-antigravity-session-state.py" <Event>`.

## Test

```
for t in tests/test_*.py; do python3 "$t"; done
```
