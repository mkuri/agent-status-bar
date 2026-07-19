# agent-status-bar — Quieter alerts — Design

Date: 2026-07-19
Status: Proposed

Follow-up to `2026-07-18-agent-status-bar-design.md`. Refines only the alert
engine's sound behavior; the state contract, rendering, and blink logic are
unchanged.

## Motivation

Three annoyances observed in daily use:

1. **Startup ding.** Launching a Claude Code session fires an entry sound.
   `SessionStart` maps to `idle`, and the app plays the idle entry sound
   (`immediate_sound_idle ?? sound_idle`, "Tink" by default) the moment a
   session first appears. Every new terminal thus dings, which is noise.

2. **Sounds pile up.** There is no minimum gap between sounds. While working
   across several sessions, an entry sound from one session and a threshold
   nag from another land back-to-back, and multiple nags can fire in quick
   succession. It reads as "constant dinging" even while actively working.

3. **Nag while composing a reply.** Whilst the user types a reply, the session
   is `idle`, and the idle threshold nag fires at `idle_alert_sec` even though
   the user is actively engaged. There is no signal for "the user is typing
   into *this* session": Claude Code emits no per-keystroke hook, the process
   is blocked on `read` (no CPU), and CPU-based activity detection only covers
   `permission`. The only precise signal is per-session terminal-pane focus,
   which requires accessibility permissions and fragile tmux/window
   introspection — contrary to the terminal-agnostic architecture. **This
   concern is therefore out of scope** (see Non-goals). Fixes #1 and #2 reduce
   its symptom: no startup ding, and nags no longer cluster.

## Terminology

- **Entry sound** — played the moment a session enters a waiting state
  (`permission` or `idle`). One shot per transition. These are important
  ("Claude finished" / "Claude needs permission") and remain unthrottled.
- **Threshold nag** — played once a session has waited past its per-state
  threshold (`permission_alert_sec` / `idle_alert_sec`). One shot per waiting
  episode. These are what pile up, and are the only sounds the cooldown gates.

## Decisions

### D1 — First sight of a session is silent

Entry sounds fire only on a genuine state transition of a session the app has
seen before. The very first time a session id is observed, it is recorded but
produces no entry sound.

- Launching a new Claude Code session (`SessionStart → idle`, first sight) is
  silent — fixes the startup ding.
- App restart re-observes existing sessions as first sight — silent, matching
  today's seeding intent.
- A known session transitioning `running → idle` (finished) or
  `running → permission` (needs approval) is *not* first sight — its entry
  sound still fires, so the useful pings are preserved.

This generalises the current `primed` seeding: "first sight ⇒ no entry sound"
subsumes "app just launched ⇒ no entry-sound burst". The threshold nag is
unaffected — a session already past threshold on first sight may still nag
(throttled by D2).

### D2 — Cooldown gates threshold nags only

A single global minimum gap, `sound_cooldown_sec` (new config, default 120,
`0` disables), applied to threshold nags only:

- **Entry sounds always play** and are never gated by the cooldown. Each
  emitted sound (entry *or* nag) updates the "last sound" timestamp.
- **A threshold nag plays only if** at least `sound_cooldown_sec` has elapsed
  since the last emitted sound. Otherwise it is **deferred**: the nag is *not*
  marked as fired, so it retries on a later tick and rings in the next quiet
  gap. If the waiting episode resolves first (state/`since` changes), its key
  disappears and the deferred nag is naturally dropped.

Consequences:

- Nags are spaced at least `sound_cooldown_sec` apart, and a nag arriving right
  after an entry ding is pushed out — killing the "constant dinging" feel while
  the entry moment itself still rings.
- At most one nag per tick: the first nag to play sets the last-sound timestamp
  to *now*, so any further nag in the same tick fails the gap check and defers.
- On app restart with several already-over-threshold sessions, only one nag
  fires; the rest defer across subsequent ticks instead of bursting.
- A nag can be starved while entry sounds keep firing inside every cooldown
  window, but that only happens amid a stream of transitions the user is
  already hearing; it fires once activity settles. Acceptable.

Ordering within a tick: emit qualifying entry sounds first (each updates the
timestamp), then at most one threshold nag, preferring `permission` over
`idle`.

### D3 — Align the permission threshold default

Change the default `permission_alert_sec` from **120 → 300**, matching
`idle_alert_sec`. Two minutes is too eager: while responding to another
session it elapses easily, so a blocked permission nags before the user has
stepped away. The `permission` entry ding still fires immediately on entering
the state, so a genuine block is not missed; only its follow-up nag waits
longer. Any machine that wants it shorter can override in config.

Activity detection is unchanged: a `permission` whose process tree is using CPU
is still shown as `running` and never nags.

## Config changes

`Config` gains one key and one default change; all keys remain optional and
re-read every 5 s.

| Key | Old default | New default | Notes |
| --- | --- | --- | --- |
| `permission_alert_sec` | 120 | 300 | D3 |
| `sound_cooldown_sec` | — | 120 | D2; new; `0` disables |

`idle_alert_sec` (300), sounds, `blink`, activity-detection, and the
`immediate_sound_*` overrides are unchanged.

## Affected components

- **`StateModel`** — the only behavioural change.
  - Add `knownSessions: Set<String>` keyed by `agent|sessionID`; compute
    `firstSight` per session before updating it (D1). This supersedes the
    `primed` flag.
  - Add `lastSoundAt: Date?`; gate nags and record emissions (D2).
  - Keep `alertedKeys` / `seenEntryKeys`; a deferred nag simply is not inserted
    into `alertedKeys` until it actually plays.
  - `evaluate` still returns `DisplayOutput`; `soundsToPlay` now carries at
    most the unthrottled entry sounds plus at most one nag.
- **`Config`** — add `sound_cooldown_sec` parsing; change `permissionAlertSec`
  default to 300.
- **`main.swift`** — no logic change (still plays every name in `soundsToPlay`).
- **Producer (dotfiles)** — unchanged.

## Testing

`StateModelTests` / `ConfigTests` cover the new behaviour with injected `now`
and config (the model is already time-injected and pure):

- First sight in `idle` emits no entry sound; a later `running → idle`
  transition on the same session id does.
- App-restart seeding: pre-existing sessions on the first `evaluate` are silent.
- A nag within `sound_cooldown_sec` of a prior sound is withheld, then fires on
  a later `evaluate` once the gap elapses; a resolved episode drops it.
- An entry sound emitted this tick defers a nag in the same tick.
- Two sessions over threshold in one tick emit exactly one nag (`permission`
  preferred), the other deferred.
- `Config` parses `sound_cooldown_sec` and defaults `permission_alert_sec` to
  300; `0` disables the cooldown.

README's Configuration section is updated: new defaults, the
`sound_cooldown_sec` key, and a sentence distinguishing always-on entry sounds
from cooldown-gated nags.

## Non-goals

- **Presence-aware nag suppression (concern #3).** Suppressing the nag only
  while the user types into that specific session needs per-session terminal
  focus (accessibility + tmux/window introspection), which is fragile and
  breaks the terminal-agnostic contract. Deferred; may be revisited as an
  opt-in later.
- No change to the state contract, rendering, blink, or activity detection.
- No collapsing of simultaneous entry sounds — entry dings are deliberately
  unthrottled per user preference.
