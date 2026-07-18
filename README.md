# agent-status-bar

Minimal macOS menu bar app showing every Claude Code session on the
machine at a glance: running / waiting-for-permission / awaiting-
instruction counts rendered as monochrome SF Symbols, with sound +
blink alerts when a session has been waiting past a threshold.

## How it works

A Claude Code hook (`record-session-state.py`, managed in the dotfiles
repo) writes one JSON state file per session to
`${XDG_STATE_HOME:-~/.local/state}/claude-sessions/`. This app is a
pure consumer of those files; any other frontend could read the same
contract. Schema and design:
`docs/superpowers/specs/2026-07-18-agent-status-bar-design.md`.

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
      "permission_alert_sec": 120,
      "idle_alert_sec": 300,
      "sound_permission": "Glass",
      "sound_idle": "Tink",
      "blink": true,
      "activity_detection": true,
      "activity_cpu_threshold_pct": 3.0
    }

A sound plays once the moment a session starts waiting (same sound as
that state's threshold alert by default), and again if it keeps waiting
past the threshold. Optional `immediate_sound_permission` /
`immediate_sound_idle` keys override the entry sound. Sounds are system
sound names from /System/Library/Sounds; "" disables a sound.

## Producer setup

The hook script and its registration live in the dotfiles repo
(`claude/hooks/record-session-state.py` plus a `hooks` block in
`claude/settings.json`). Without a producer this app just shows a
dimmed terminal glyph.

## Testing

    cd StatusBarApp && swift test            # consumer unit tests
    scripts/fake-session.sh                  # visual E2E without a producer
