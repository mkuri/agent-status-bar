# agent-status-bar

Minimal macOS menu bar app showing every Claude Code and Antigravity CLI
(`agy`) session on the machine at a glance: running / waiting-for-permission
/ awaiting-instruction counts rendered as monochrome SF Symbols, with sound +
blink alerts when a session has been waiting past a threshold.

## How it works

This repo has two peers: a **producer** (`session-state-recorder/`) and a
**consumer** (`StatusBarApp/`, one UI example). The producer's hook scripts
write one JSON state file per session into
`${XDG_STATE_HOME:-~/.local/state}/claude-sessions/` (Claude Code) and
`antigravity-sessions/` (Antigravity CLI, `agy`). The app is a pure consumer of
those files — any other frontend could read the same contract. Schema and
design: `docs/superpowers/specs/2026-07-18-agent-status-bar-design.md`.

Antigravity currently reports `running` / `idle` only (it exposes no permission
hook) — see the design doc. The bar counts are machine-wide totals across both
agents; each dropdown row is tagged with its agent (`claude · project` /
`agy · project`).

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

Without a producer the app just shows a dimmed terminal glyph. Install the
hooks that feed it:

    session-state-recorder/setup.sh

It interactively registers the Claude Code and/or Antigravity hooks (idempotent,
backs up what it edits, and skips a symlinked `settings.json`). Requires
`python3`. Manual setup and the state-file contract are documented in
[`session-state-recorder/README.md`](session-state-recorder/README.md).

## Testing

    cd StatusBarApp && swift test            # consumer unit tests
    scripts/fake-session.sh                  # visual E2E without a producer

## License

MIT — see [LICENSE](LICENSE).
