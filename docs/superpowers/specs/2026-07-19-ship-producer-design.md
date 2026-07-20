# Ship the producer (`session-state-recorder/`) — Design

**Status:** proposed. Depends on nothing already merged; touches this repo
(new `session-state-recorder/`, docs) and, separately, the maintainer's private
dotfiles (migration performed by the maintainer, not this repo's CI).

## Overview

The *producer* — the hook adapters plus the shared library that record agent
session state into the versioned state-file contract — currently lives only in
the maintainer's private dotfiles. Because of that, an external user who clones
and runs this app sees only a dimmed terminal glyph: the consumer has nothing
to read. Shipping the app as usable open source requires shipping the producer.

This design moves the producer into this public repo as the **single source of
truth**, ships an **interactive, opt-in installer**, and migrates the
maintainer's dotfiles to *reference* the repo copy — so the scripts are never
maintained in two places (no double management).

### Goals

- An external user can get real data working: the producer is present,
  documented, and installable.
- Single source of truth for the producer. Dotfiles keeps no copy; it points at
  the repo copy.
- Preserve the producer/consumer architecture as a first-class idea: the
  recorder is general and OS-independent; the status bar is one UI example.
- Installer is interactive and treats Claude and Antigravity independently —
  it registers only what the user actually uses.
- **Zero behavior change** to the recording logic. The only code edit is how a
  hook locates its sibling helper.

### Non-goals

- Renaming the repo or fixing a bundle id (its own dedicated session). Note the
  path coupling this creates — see Known dependencies.
- A Linux (or any non-macOS) UI consumer. The layout accommodates one as a
  sibling; we do not build it (YAGNI).
- An uninstaller. Manual removal is documented instead.
- Release binaries / Homebrew / notarization — later checklist items.

## Architecture: producer / consumer split

The repo holds two peers, kept flat (no grouping layer while there is exactly
one of each):

```
session-state-recorder/   # producer: writes the versioned state-file contract (Python, stdlib only)
StatusBarApp/             # consumer: one UI example (macOS menu bar, Swift)
                          # future: a linux-ui/ sibling could consume the same contract
```

A `producer/` + `consumer/` grouping layer is deliberately **not** introduced
now: with one producer and one consumer it only lengthens every path
(`setup.sh`, the embedded command in `settings.json`, CI, docs) for no present
benefit. When a second producer or consumer actually lands, `git mv` into a
grouping layer is cheap and has no external dependents. The producer/consumer
*vocabulary* lives in prose (README) rather than in directory nesting.

## Directory move

The three producer files and their tests move out of dotfiles into a
self-contained directory:

```
session-state-recorder/
  session_state.py                     # shared helper (from dotfiles agent-session-state/)
  record-session-state.py              # Claude Code adapter (from dotfiles claude/hooks/)
  record-antigravity-session-state.py  # Antigravity adapter (from dotfiles gemini/hooks/)
  setup.sh                             # interactive installer (new)
  tests/
    test_session_state.py                          # from dotfiles agent-session-state/tests/
    test_record_session_state.py                   # from dotfiles claude/hooks/tests/
    test_record_antigravity_session_state.py       # from dotfiles gemini/hooks/tests/
  README.md                            # contract + install/registration (new)
```

## Code change (the only one)

Both adapters currently locate the shared helper with a dotfiles-layout
assumption:

```python
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "agent-session-state"))
import session_state
```

Change to make the directory self-contained (helper is a sibling), so it works
both inside the repo and when a command points at it from anywhere:

```python
sys.path.insert(0, str(Path(__file__).resolve().parent))
import session_state
```

`Path(__file__).resolve()` still resolves through any symlink to the real file
in `session-state-recorder/`, whose sibling is `session_state.py`. No other
logic changes; the recorded schema (`STATE_VERSION = 1`) is unchanged.

## Installer: `session-state-recorder/setup.sh`

Interactive; Claude and Antigravity are independent and both optional.

- **Recorder path resolution.** `<RECORDER>` = the installer's own directory,
  the absolute `session-state-recorder/` path (`cd "$(dirname "$0")" && pwd`).
  Whatever path it embeds in a command is correct for wherever the user cloned
  the repo. Moving the repo means re-running `setup.sh`.
- **Claude prompt** (default derived from whether `~/.claude/` exists). If yes:
  - Refuse-with-warning if `~/.claude/settings.json` is a **symlink** ("looks
    dotfiles-managed; edit your dotfiles instead") — this protects the
    maintainer, whose settings.json is symlinked into dotfiles, from an
    accidental in-place edit.
  - Otherwise back up `settings.json` (timestamped copy), then do an
    **idempotent JSON merge** (stdlib `python3`, no `jq`) of the nine-event
    block below. Merge is keyed on the command path: for each event, insert our
    hook only if an entry with that command is not already present; existing
    unrelated hooks are preserved.
  - Embedded command: `python3 "<RECORDER>/record-session-state.py"`, `"timeout": 5`.
    The nine events (parity with the tested config): `SessionStart`,
    `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `PostToolUseFailure`,
    `Stop`, `StopFailure`, `Notification` (with `"matcher": "idle_prompt"`),
    `SessionEnd`.
- **Antigravity prompt** (default derived from whether `~/.gemini/` exists). If
  yes: back up / create `~/.gemini/config/hooks.json` and merge `PreInvocation`
  and `Stop` entries whose command is
  `python3 "<RECORDER>/record-antigravity-session-state.py" <Event>`.
- **Summary.** Print what changed, the backup paths, and where state files will
  appear (`~/.local/state/claude-sessions/`,
  `~/.local/state/antigravity-sessions/`, honoring `XDG_STATE_HOME`).
- Re-running is safe (idempotent) and touches only the agents the user selects.

## Maintainer migration (dotfiles; committed by the maintainer)

Option 1 ("repoint the command"), chosen because it keeps a single source of
truth without a committed cross-repo symlink and because the command path itself
documents where the script comes from. The maintainer does **not** run
`setup.sh` (their `~/.claude/settings.json` is a live symlink into dotfiles);
they edit dotfiles directly, which takes effect immediately.

- `dotfiles/claude/settings.json` — repoint all nine commands from
  `$HOME/.claude/hooks/record-session-state.py` to
  `$HOME/projects/agent-status-bar/session-state-recorder/record-session-state.py`.
- `dotfiles/gemini/config/hooks.json` — repoint both commands to
  `$HOME/projects/agent-status-bar/session-state-recorder/record-antigravity-session-state.py`.
- Delete `dotfiles/claude/hooks/record-session-state.py`,
  `dotfiles/gemini/hooks/record-antigravity-session-state.py`, and
  `dotfiles/agent-session-state/`.
- Drop the now-unused `~/.gemini/hooks` symlink wiring (only this one script
  lived there); the `~/.gemini/config/hooks.json` symlink stays.

## Documentation

- **Top-level `README.md`.** Lead with the producer/consumer framing; add full
  install steps (build the app, then run `session-state-recorder/setup.sh`);
  link the state-file contract. Update the existing "Producer setup" and
  "How it works" sections that currently point at dotfiles.
- **`session-state-recorder/README.md`.** What it is, the versioned contract,
  the manual hooks block / `hooks.json` (for users who prefer editing config by
  hand), `setup.sh` usage, and state-file locations.
- **`TODO.md`.** Check off "Ship / document the producer."

## Testing

- Move the three Python test files into `session-state-recorder/tests/` and
  confirm they pass with the self-contained `sys.path` change
  (`python3 -m pytest` or `unittest` discovery from the directory).
- Swift consumer tests are unaffected (44/44 stay green).
- Manual E2E for the installer: run `setup.sh` against a scratch `HOME` with a
  throwaway `settings.json`; verify (a) fresh install writes all nine events,
  (b) a second run is a no-op, (c) an existing unrelated hook is preserved,
  (d) a symlinked `settings.json` is refused with a clear message, (e) a backup
  is created.
- CI (next topic) will run the Python tests and `swift test` together.

## Ownership (updated — supersedes the prior boundary)

The Antigravity design doc states the app repo "never touches dotfiles /
`~/.gemini`." This design **intentionally revises** that: the producer now lives
in this repo, and its opt-in, interactive installer writes to
`~/.claude/settings.json` and `~/.gemini/config/hooks.json` **when the user asks
it to**. The maintainer's own machine stays dotfiles-managed — the installer
refuses to edit a symlinked `settings.json`, so the maintainer path and the
external-user path do not collide.

## Known dependencies / limitations

- The maintainer's `settings.json` embeds the local clone path
  (`$HOME/projects/agent-status-bar/...`). Renaming the local directory — or the
  repo, in the deferred naming session — requires a find/replace of those paths.
  Cheap and local, but a coupling to remember before the naming decision locks
  in.
- The installer and the producer require `python3` (already the producer's only
  dependency; stdlib only).

## References

- `docs/superpowers/specs/2026-07-18-agent-status-bar-design.md` — base design,
  state contract, prior "producer owned by dotfiles" ownership note.
- `docs/superpowers/specs/2026-07-18-antigravity-support-design.md` — Antigravity
  hook model, `~/.gemini/config/hooks.json` registration, prior boundary
  statement this design supersedes.
- Current producer sources in dotfiles: `agent-session-state/session_state.py`,
  `claude/hooks/record-session-state.py`,
  `gemini/hooks/record-antigravity-session-state.py`.
