# agent-status-bar

Minimal macOS menu bar app showing every Claude Code and Antigravity CLI
(`agy`) session on the machine at a glance: running / waiting-for-permission
/ awaiting-instruction counts rendered as monochrome SF Symbols, with sound +
blink alerts when a session has been waiting past a threshold.

## How it works

A Claude Code hook (`record-session-state.py`, managed in the dotfiles
repo) writes one JSON state file per session to
`${XDG_STATE_HOME:-~/.local/state}/claude-sessions/`. This app is a
pure consumer of those files; any other frontend could read the same
contract. Schema and design:
`docs/superpowers/specs/2026-07-18-agent-status-bar-design.md`.

The Antigravity CLI producer (`record-antigravity-session-state.py`, also in
the dotfiles repo) writes the same contract into `antigravity-sessions/`. The
app reads both directories and tags each dropdown row with its agent
(`claude · project` / `agy · project`); the bar counts are machine-wide totals
across both. Antigravity currently reports `running` / `idle` only (it exposes
no permission hook) — see the design doc.

## Build and run

    cd StatusBarApp
    swift build -c release
    .build/release/AgentStatusBar &

Requires macOS 13+, Apple Silicon, Swift 5.9+ toolchain.

## Start at login (optional)

    sed "s|__REPO__|$PWD|" scripts/com.agent-status-bar.plist \
      > ~/Library/LaunchAgents/com.agent-status-bar.plist
    launchctl load ~/Library/LaunchAgents/com.agent-status-bar.plist

## Configuration

`~/.config/agent-status-bar/config.json` — all keys optional,
re-read every 5 s:

    {
      "permission_alert_sec": 300,
      "idle_alert_sec": 300,
      "sound_permission": "Glass",
      "sound_idle": "Tink",
      "sound_cooldown_sec": 120,
      "blink": true,
      "activity_detection": true,
      "activity_cpu_threshold_pct": 3.0
    }

A session's first sighting is silent, so launching a session does not ding.
Afterwards a sound plays the moment a session enters a waiting state (same
sound as that state's threshold alert by default), and again if it keeps
waiting past the threshold. The entry sound always plays; the past-threshold
nag is rate-limited by `sound_cooldown_sec` (default 120 s; `0` disables) so
nags never land within that gap of another sound — a gated nag is deferred to
the next quiet gap rather than dropped. Optional `immediate_sound_permission` /
`immediate_sound_idle` keys override the entry sound. Sounds are system sound
names from /System/Library/Sounds; "" disables a sound.

## Producer setup

The hook script and its registration live in the dotfiles repo
(`claude/hooks/record-session-state.py` plus a `hooks` block in
`claude/settings.json`). Without a producer this app just shows a
dimmed terminal glyph.

The Antigravity producer lives in the same dotfiles repo (`gemini/hooks/` plus a
`hooks.json` registered at the CLI's global customization root) and shares the
atomic-write helper with the Claude producer.

## Testing

    cd StatusBarApp && swift test            # consumer unit tests
    scripts/fake-session.sh                  # visual E2E without a producer
