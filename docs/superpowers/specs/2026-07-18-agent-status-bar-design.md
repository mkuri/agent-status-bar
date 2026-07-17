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

The system is split into two independently owned layers that communicate
only through state files on disk:

- **Producer (owned by the dotfiles repo)** — a hook script that records
  every Claude Code session's state to a well-known location. This is a
  basic capability of the user's Claude Code setup: it works on any machine
  after dotfiles setup and has no knowledge of any display tool.
- **Consumer (this repo, agent-status-bar)** — a menu bar app that renders
  those state files. It is one possible frontend; anything else (a CLI, a
  widget, a tmux status line) could read the same files.

The state-file format and location are the contract between the layers (see
"State contract"). Hook events are pushed by Claude Code itself, so
detection works identically in any terminal, tmux, or IDE.

```
Claude Code session (any terminal / tmux pane)
    │  hooks (see State model)
    ▼
~/projects/dotfiles/claude/hooks/record-session-state.py      [dotfiles-owned]
    │  Python 3 stdlib only, ~60 lines; referenced in settings.json as
    │  $HOME/.claude/hooks/record-session-state.py (symlink created by dotfiles
    │  setup.sh — no dependency on this repo's location)
    │  reads event JSON from stdin,
    │  writes state file atomically (tmp + rename)
    ▼
~/.local/state/claude-sessions/<session_id>.json        [the contract]
    ▲
    │  directory watch (DispatchSource) + 5 s timer
StatusBarApp                          [this repo] Swift, SPM, no deps
    ├─ menu bar: SF Symbol glyphs + counts, monochrome template rendering
    ├─ dropdown: one text row per session + Quit
    └─ alert engine: sound (NSSound) + blink on threshold breach
```

### State contract

One JSON file per live session at
`~/.local/state/claude-sessions/<session_id>.json` (XDG state dir —
machine-local execution state, deliberately not `~/.local/share`, which is
for portable data). The directory is named for the data, not for any
consumer.

```json
{
  "version": 1,
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
- `version` increments only on breaking changes to this schema; consumers
  skip files whose `version` is newer than they understand and must tolerate
  unknown extra fields.

## State model and hook wiring

Three session states, rendered with SF Symbols:

| State | Meaning | Glyph |
| --- | --- | --- |
| `running` | Claude is working | `play.fill` |
| `permission` | Blocked on a permission dialog | `hand.raised.fill` |
| `idle` | Finished responding / awaiting next instruction | `checkmark.circle` |

Hook events registered in `~/.claude/settings.json` (a symlink into the
user's dotfiles — see "Ownership and dotfiles integration") and their
mapping:

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

### `record-session-state.py` (lives in dotfiles: `claude/hooks/record-session-state.py`)

- Read one JSON payload from stdin; extract `hook_event_name`, `session_id`,
  `cwd`; map to a state; write/delete the state file atomically.
- Entire body wrapped in `try/except: pass`; always exits 0; never writes to
  stdout — a monitoring hook must never break or slow Claude Code.
- Stdlib only (`json`, `os`, `sys`, `tempfile`, `pathlib`).
- Core logic in `handle_event(payload: dict, state_dir: Path)` for unit
  testing; `__main__` is a thin stdin wrapper.
- Knows nothing about agent-status-bar; its only obligation is the state
  contract above.

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

## Ownership and dotfiles integration

The user's Claude Code configuration is managed in
`~/projects/dotfiles/claude`: `~/.claude/settings.json` and
`~/.claude/hooks` are symlinks into that git-tracked directory. Ownership
is split so that the foundational layer never depends on this project:

**Dotfiles own the producer.** `record-session-state.py` lives in
`~/projects/dotfiles/claude/hooks/` next to the existing hook scripts, and
the hook entries in `~/projects/dotfiles/claude/settings.json` reference it
as `$HOME/.claude/hooks/record-session-state.py`. After dotfiles `setup.sh` on any
machine, session state recording works with no other repo present. Both
changes are committed through the user's normal dotfiles flow; nothing in
this project programmatically mutates `~/.claude/settings.json`. The
dotfiles repo currently registers no hooks, so the block introduces the
`hooks` key; if other hooks (e.g. the existing `notify-on-stop.sh`) are
enabled later, Claude Code runs all matching hooks independently — no
conflict.

**This repo owns one consumer.** agent-status-bar reads
`~/.local/state/claude-sessions/` and renders it. If the directory is
missing or empty it shows the quiet glyph; installing or removing the app
never touches dotfiles. Its README documents the state contract it consumes
and points at the dotfiles hook as the reference producer.

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
  the hook entries in dotfiles `settings.json` are the single place listing
  event names.

## Testing

- **Python (`unittest`, lives in dotfiles next to the script)**: event
  payload → expected state file transitions, including `since` preservation
  on same-state events, `SessionEnd` deletion, and malformed-payload no-ops.
  Run manually with `python3 -m unittest` in `claude/hooks/`; the kebab-case
  script is loaded via `importlib`.
- **Swift (XCTest via SPM)**: `StateModel` aggregation — counts, zero-count
  hiding, threshold crossing exactly once per state entry, blink set
  contents, stale filtering, activity-detection override. Contract fixtures
  (sample state files) keep the consumer testable without the producer.
- **Manual E2E**: `scripts/fake-session.sh` writes a scripted sequence of
  contract state files to drive the bar visually — no producer needed; real
  sessions in tmux/Ghostty as full-stack final verification.

## Repository layout

```
agent-status-bar/                     [this repo — consumer only]
├── docs/superpowers/specs/2026-07-18-agent-status-bar-design.md
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

dotfiles (~/projects/dotfiles)        [producer — committed by the user]
└── claude/
    ├── settings.json                 + hooks entries
    └── hooks/
        ├── record-session-state.py          the producer script
        └── tests/test_record_session_state.py
```

Build: `swift build -c release` (Apple Silicon, macOS 13+). No Xcode project,
no external dependencies, no code signing required for personal use.

## References

- [m1ckc3s/claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)
  (577★, MIT) — reference for Swift menu bar patterns.
- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) —
  event list current as of 2026-07-18.
