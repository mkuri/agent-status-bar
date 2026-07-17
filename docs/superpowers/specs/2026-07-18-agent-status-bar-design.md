# agent-status-bar — Design

Date: 2026-07-18
Status: Approved (pending final spec review)

## Overview

A minimal macOS menu bar app that shows, at a glance, the state of every
Claude Code session running on the machine. Counts are always visible in the
menu bar itself — no click required. When a session has been waiting for user
action beyond a configurable threshold, the app alerts with a sound and a
blinking indicator.

The user runs multiple Claude Code sessions inside tmux panes in Ghostty.
Detection is terminal-agnostic (see Architecture), so tmux/Ghostty specifics
do not affect the design.

### Goals

1. Always-visible counts in the menu bar: running / waiting-for-permission /
   awaiting-instruction sessions.
2. Timed alerts: sound + blink when a session stays in a waiting state past a
   per-state threshold (defaults: permission 120 s, idle 300 s). All
   thresholds and sounds are parameterized in a config file.
3. Minimal, monochrome design using SF Symbols that blends into the standard
   macOS menu bar.

### Non-goals

- Token/quota/cost tracking
- Jumping focus to the owning terminal pane
- Controlling sessions (approve/deny from the menu)
- Support for agents other than Claude Code
- macOS Notification Center banners (sound + blink only)

## Architecture

Two components communicate through state files. Hook events are pushed by
Claude Code itself, so detection works identically in any terminal, tmux, or
IDE.

```
Claude Code session (any terminal / tmux pane)
    │  hooks (see State model)
    ▼
hooks/agent_status_hook.py           Python 3 stdlib only, ~60 lines
    │  reads event JSON from stdin,
    │  writes state file atomically (tmp + rename)
    ▼
~/.local/state/agent-status-bar/sessions/<session_id>.json
    ▲
    │  directory watch (DispatchSource) + 5 s timer
StatusBarApp                          Swift, SPM executable, no dependencies
    ├─ menu bar: SF Symbol glyphs + counts, monochrome template rendering
    ├─ dropdown: one text row per session + Quit
    └─ alert engine: sound (NSSound) + blink on threshold breach
```

### State file

`~/.local/state/agent-status-bar/sessions/<session_id>.json`

```json
{
  "session_id": "…",
  "state": "running" | "permission" | "idle",
  "since": 1752800000.0,
  "cwd": "/path/to/project",
  "pid": 12345,
  "updated_at": 1752800400.0
}
```

- `since` changes only when `state` changes, so elapsed time in a state is
  meaningful. Repeated same-state events update `updated_at` only.
- `pid` is the Claude Code process PID, captured as the hook process's parent
  PID (`os.getppid()`). Hooks are spawned directly by the claude process, so
  this holds under tmux as well.

## State model and hook wiring

Three session states, rendered with SF Symbols:

| State | Meaning | Glyph |
| --- | --- | --- |
| `running` | Claude is working | `play.fill` |
| `permission` | Blocked on a permission dialog | `hand.raised.fill` |
| `idle` | Finished responding / awaiting next instruction | `checkmark.circle` |

Hook events registered in `~/.claude/settings.json` (a symlink into the
user's dotfiles — see "Hook registration via dotfiles") and their mapping:

| Hook event | New state |
| --- | --- |
| `SessionStart` | `idle` |
| `UserPromptSubmit` | `running` |
| `PermissionRequest` | `permission` |
| `PostToolUse`, `PostToolUseFailure` | `running` |
| `Stop`, `StopFailure` | `idle` |
| `Notification` (matcher `idle_prompt`) | `idle` |
| `SessionEnd` | state file deleted |

Deliberately not hooked: `PreToolUse` (adds per-tool-call latency and is
redundant — `UserPromptSubmit` already sets `running`), `SubagentStart/Stop`
(subagent activity is part of a running turn).

### Activity detection (permission → running without an event)

Claude Code has no hook that fires when the user approves a permission
request; the next event is `PostToolUse` after the tool finishes. A long
command approved and left unattended would otherwise show `permission` until
completion and could fire a false alert.

Mitigation: on each 5 s tick, for sessions in `permission`, the Swift app
samples one `ps -axo pid,ppid,pcpu`, builds the process tree, and sums CPU
usage of the claude PID and all descendants. If the sum is at or above
`activity_cpu_threshold_pct` (default 3.0), the session is displayed as
`running`. This is a display-only override — state files remain the source of
truth and the next real hook event corrects them. Waiting on a permission
dialog the process tree is essentially idle, so false positives are unlikely;
the feature can be disabled with `activity_detection: false`.

## Alert engine

- `permission` for ≥ `permission_alert_sec` (default 120): play
  `sound_permission` once, blink the permission segment of the bar until the
  state changes.
- `idle` for ≥ `idle_alert_sec` (default 300): play `sound_idle` once, blink
  the idle segment.
- One sound per state entry: bookkeeping keyed on `(session_id, since)`, so
  re-entering a state re-arms the alert but nothing repeats within one stay.
- Blink: 0.5 s timer toggling the segment's alpha. Monochrome only — no
  color, per the minimal design goal.

### Config

`~/.config/agent-status-bar/config.json`, re-read on every 5 s tick (no
restart needed). Missing file or keys fall back to defaults.

```json
{
  "permission_alert_sec": 120,
  "idle_alert_sec": 300,
  "sound_permission": "Glass",
  "sound_idle": "Tink",
  "blink": true,
  "activity_detection": true,
  "activity_cpu_threshold_pct": 3.0
}
```

Sounds are macOS system sound names resolved via `NSSound(named:)`.

## Menu bar UI

- `NSStatusItem` with an attributed title: SF Symbol template images
  (`NSTextAttachment`) followed by counts, e.g. `⏵ 2  ✋ 1  ✓ 1` rendered as
  `play.fill 2  hand.raised.fill 1  checkmark.circle 1`.
- Template rendering keeps everything monochrome and automatically adapts to
  the menu bar appearance (matches the user's existing white-on-dark bar).
- Segments with count 0 are hidden. With no live sessions, a single dimmed
  `terminal` glyph is shown.
- Dropdown menu: one row per session — `basename(cwd)  state glyph  elapsed`
  (e.g. `my-app  ⏵  3m`), a separator, and Quit. No other chrome.
- The app is a plain SPM executable with activation policy `.accessory`
  (no Dock icon, no main window).

## Component responsibilities

### `hooks/agent_status_hook.py`

- Read one JSON payload from stdin; extract `hook_event_name`, `session_id`,
  `cwd`; map to a state; write/delete the state file atomically.
- Entire body wrapped in `try/except: pass`; always exits 0; never writes to
  stdout — a monitoring hook must never break or slow Claude Code.
- Stdlib only (`json`, `os`, `sys`, `tempfile`, `pathlib`).
- Core logic in `handle_event(payload: dict, state_dir: Path)` for unit
  testing; `__main__` is a thin stdin wrapper.

### `StatusBarApp` (Swift)

- `main.swift` — NSApplication setup, NSStatusItem, DispatchSource directory
  watch, 5 s timer, menu construction.
- `StateModel.swift` — pure, testable core: `[SessionSnapshot] + now +
  Config → (bar segments, menu rows, alerts to fire, blink set)`. Also owns
  stale-session filtering and the alert-once bookkeeping.
- `Config.swift` — config file decoding with defaults.
- `ProcessProbe.swift` — PID liveness (`kill(pid, 0)`) and the CPU-tree
  sampler (`ps` once per tick, shared across sessions).

### `scripts/`

- `fake-session.sh` — E2E driver (see Testing).
- `com.agent-status-bar.plist` — optional LaunchAgent template for start at
  login; installing it is a manual, documented step.

## Hook registration via dotfiles

The user's Claude Code configuration is managed in
`~/projects/dotfiles/claude`: `~/.claude/settings.json` and
`~/.claude/hooks` are symlinks into that git-tracked directory. Therefore
**nothing in this project programmatically mutates `~/.claude/settings.json`**
— doing so would dirty the dotfiles working tree behind the user's back.

Instead, hook registration is a one-time edit to
`~/projects/dotfiles/claude/settings.json`, committed through the user's
normal dotfiles flow. The hook `command` entries reference this repository
by absolute path (`$HOME/projects/agent-status-bar/hooks/agent_status_hook.py`),
so the script itself stays versioned here, next to the app that consumes its
output. README carries the exact JSON block to paste. The dotfiles repo
currently registers no hooks, so the block introduces the `hooks` key; if
other hooks (e.g. the existing `notify-on-stop.sh`) are enabled later, Claude
Code runs all matching hooks independently — no conflict.

## Error handling and edge cases

- Terminal pane killed without `SessionEnd`: sessions whose `pid` is dead
  (`kill(pid, 0)` fails) are removed on the next tick; additionally any state
  file older than 24 h (`updated_at`) is ignored and deleted.
- Malformed or empty state files: skipped silently (atomic rename makes this
  rare).
- Missing state/config directories: created by whichever side touches them
  first; the app shows the quiet glyph when there is nothing to report.
- Hook script failure: silent by design; the bar simply shows stale data
  until the next successful event or cleanup.
- Plan-mode approval (`ExitPlanMode`) surfaces as a permission dialog →
  handled by the `permission` flow.

### Known limitations

- `AskUserQuestion`-style dialogs are not permission requests: the session
  shows `running` until the `idle_prompt` notification (~60 s) flips it to
  `idle`.
- Approval of a non-CPU-bound long tool (rare; most long tools are
  subprocess-based) may keep `permission` displayed until `PostToolUse`.
- If Claude Code renames hook events in a future release, the hook script
  ignores unknown events and the bar degrades to stale-data cleanup;
  `install-hooks.py` is the single place listing event names.

## Testing

- **Python (`unittest`)**: event payload → expected state file transitions,
  including `since` preservation on same-state events, `SessionEnd` deletion,
  and malformed-payload no-ops.
- **Swift (XCTest via SPM)**: `StateModel` aggregation — counts, zero-count
  hiding, threshold crossing exactly once per state entry, blink set
  contents, stale filtering, activity-detection override.
- **Manual E2E**: `scripts/fake-session.sh` pipes a scripted sequence of hook
  payloads through `agent_status_hook.py` to drive the bar visually; real
  sessions in tmux/Ghostty as final verification.

## Repository layout

```
agent-status-bar/
├── docs/superpowers/specs/2026-07-18-agent-status-bar-design.md
├── hooks/agent_status_hook.py
├── StatusBarApp/
│   ├── Package.swift
│   ├── Sources/AgentStatusBar/
│   │   ├── main.swift
│   │   ├── StateModel.swift
│   │   ├── Config.swift
│   │   └── ProcessProbe.swift
│   └── Tests/AgentStatusBarTests/StateModelTests.swift
├── scripts/
│   ├── fake-session.sh
│   └── com.agent-status-bar.plist
└── README.md
```

Build: `swift build -c release` (Apple Silicon, macOS 13+). No Xcode project,
no external dependencies, no code signing required for personal use.

## References

- [m1ckc3s/claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)
  (577★, MIT) — reference for hook merge strategy and Swift menu bar
  patterns.
- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) —
  event list current as of 2026-07-18.
