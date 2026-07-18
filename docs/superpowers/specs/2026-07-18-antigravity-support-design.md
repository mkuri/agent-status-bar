# Antigravity CLI (`agy`) support — Design

Date: 2026-07-18
Status: Approved (pending final spec review)

## Overview

Extend `agent-status-bar` so the menu bar shows **Antigravity CLI (`agy`)**
sessions alongside **Claude Code** sessions, using the same architecture,
state-file contract, and rendering. A running/permission/idle count in the bar
becomes a machine-wide total across both agents; the dropdown distinguishes
which agent owns each session.

This design mirrors the existing Claude Code design
(`2026-07-18-agent-status-bar-design.md`) — read it first; this document only
describes the antigravity delta and the small shared refactors it motivates.

### Goals

1. Antigravity sessions appear in the same bar and dropdown as Claude sessions,
   with counts aggregated across both agents.
2. Reuse the existing state-file contract unchanged (schema `version: 1`,
   identical fields); the owning agent is inferred from the state directory,
   never stored in the file.
3. Keep the two-layer split intact: the antigravity **producer is owned by the
   dotfiles repo** (like the Claude producer); this repo stays a pure consumer.

### Non-goals

- A dedicated `permission` state for antigravity in this iteration (see
  "Antigravity has no permission event"). Antigravity ships with
  `running` / `idle` only; the permission heuristic is a documented future
  extension.
- Per-agent thresholds, sounds, or bar segments. Alerts stay keyed on state,
  not agent.
- Any change to Claude Code behavior. The Claude producer's observable output
  is unchanged; only shared helper code is extracted, guarded by its existing
  tests.

## Antigravity hook model (verified against `agy` 1.1.4)

Antigravity's lifecycle hooks are configured in a `hooks.json` at a
customization root (globally) or inside a plugin (`plugins/<name>/hooks.json`).
The events that `hooks.json` actually supports are:

| Event | When it fires | Payload structure |
| --- | --- | --- |
| `PreToolUse` | Before a tool step executes | grouped (`matcher` + `hooks`) |
| `PostToolUse` | After a tool step completes | grouped (`matcher` + `hooks`) |
| `PreInvocation` | Before the model is called | flat (handler list) |
| `PostInvocation` | After an invocation's tool calls finish | flat |
| `Stop` | When the execution loop terminates | flat |

Notable differences from Claude Code hooks:

- **No `SessionStart`, no `SessionEnd`, no `PermissionRequest`.** These exist
  in Claude but are not exposed to antigravity `hooks.json`.
- **Every hook must emit a JSON object on stdout** (at minimum `{}`). The Claude
  producer writes nothing to stdout; the antigravity producer must print `{}`.
- **`PreToolUse` output is load-bearing:** its `decision` field
  (`allow`/`deny`/`ask`/`force_ask`) can auto-approve or block tools. A
  passive monitor must not risk altering permission behavior, so this design
  **does not hook `PreToolUse`.**
- **Working directory is the `hooks.json` directory, not the workspace.** The
  producer must take `cwd` from the payload, never from `os.getcwd()`.

### Common stdin payload (camelCase, protojson)

Every hook receives these fields on stdin; the producer uses only the first two:

```json
{
  "conversationId": "ec33ebf9-0cba-4100-8142-c61503f6c587",
  "workspacePaths": ["/path/to/workspace"],
  "transcriptPath": "…/.gemini/antigravity-cli/transcript.jsonl",
  "artifactDirectoryPath": "…",
  "modelName": "auto"
}
```

The payload does **not** carry the event name, so the producer receives it as a
command-line argument (`sys.argv[1]`), one hook registration per event.

## State model and hook wiring

Two states in this iteration, using the existing `SessionState` enum. Only two
events are hooked:

| `agy` hook | Argument | New state |
| --- | --- | --- |
| `PreInvocation` | `PreInvocation` | `running` |
| `Stop` | `Stop` | `idle` |

- `PreInvocation → running` covers the whole active turn: multiple model
  invocations within one turn all map to `running` (no visible flicker since
  the state is unchanged and `since` is preserved). `PreInvocation` also
  refreshes `updated_at` / `cwd` / `pid` on each invocation, keeping the
  session out of the 24 h stale window without a separate liveness hook.
- `Stop → idle` is the "come back" signal — the main value for antigravity,
  equivalent to the Claude `Stop`/idle flow.
- **`PostToolUse` is deliberately NOT hooked.** Empirical testing against
  `agy` 1.1.4 showed the real event order for a turn is
  `PreInvocation → PostToolUse → Stop → PostToolUse (again)`: a trailing
  `PostToolUse` fires *after* `Stop` (agy's post-loop cleanup tool). Hooking
  `PostToolUse → running` therefore reset the just-set `idle` back to
  `running`, so sessions never settled to idle. Dropping it makes `Stop` the
  final event of every turn.
- There is no session-end deletion event; cleanup relies entirely on the
  consumer's existing liveness check (`kill(pid, 0)`) plus the 24 h stale
  sweep. When `agy` exits, its PID dies and the consumer removes the file on
  the next tick — the same path Claude uses for crashed sessions. Verified
  live: the recorded `pid` is the real `agy` process and is dead once `agy`
  exits.
- `cwd` comes from `workspacePaths[0]`, which is populated when the session
  has a workspace (e.g. `agy --add-dir <path>` or a project) and empty
  otherwise; a workspace-less session records `cwd: ""` and renders as
  `agy · ` (empty basename) — an accepted degradation.

### Antigravity has no permission event

Antigravity fires no hook when it blocks on a permission dialog: the dialog
appears *between* `PreToolUse` and `PostToolUse`, after `PreToolUse` returns,
and there is no dedicated event. Capturing a `permission` state would therefore
require hooking `PreToolUse` (whose output can auto-approve or block tools) and
a consumer-side heuristic. Per the approved decision, this iteration ships
`running` / `idle` only. While antigravity waits on a permission dialog it
displays as `running` (no alert); the `idle` alert still covers the primary
"awaiting instruction" case.

**Future extension (documented, not built):** once it is empirically confirmed
that a `PreToolUse` hook emitting `{}` is a safe no-op (does not change the
normal permission flow), permission can be added as the inverse of the Claude
CPU heuristic: the producer marks a pending tool on `PreToolUse`; the consumer
shows `permission` when a pending antigravity session stays CPU-idle past a
short grace period, and re-shows `running` when the tool's process tree is busy.

## Producer (owned by the dotfiles repo)

Two new files under `~/projects/dotfiles/`, plus a shared helper and a
refactor of the existing Claude producer:

```
dotfiles (~/projects/dotfiles)                    [producer — committed by the user]
├── agent-session-state/
│   └── session_state.py            NEW: shared atomic-write / since / PID helper
├── claude/
│   └── hooks/
│       └── record-session-state.py MODIFY: import the shared helper (behavior unchanged)
└── gemini/
    ├── config/
    │   └── hooks.json              NEW: registers the antigravity producer
    └── hooks/
        └── record-antigravity-session-state.py   NEW: antigravity adapter
```

### Shared helper: `agent-session-state/session_state.py`

Extracts the genuinely-identical, non-trivial logic both producers need so it
cannot drift between them:

- `write_state(state_dir, session_id, state, cwd, pid, now)` — atomic
  temp-file + `os.replace`, preserving `since` across same-state writes,
  emitting the versioned contract record.
- `resolve_agent_pid(start_pid)` — walk up past shell wrappers
  (`sh`/`bash`/`zsh`/…) to the owning agent process.
- `delete_state(state_dir, session_id)` — unlink helper (used by the Claude
  `SessionEnd`; antigravity has no delete event but shares the function).

Both producers load it with a two-line `sys.path` shim
(`sys.path.insert(0, <dotfiles>/agent-session-state)`); dotfiles `setup.sh`
symlinks the directory so the path is stable on any machine. Stdlib only.
**The Claude producer's observable behavior is unchanged and is verified by its
existing Python tests** (they must stay green after the refactor). If the
cross-directory import proves fragile on the target machine (resolved in
implementation step 0), the fallback is to duplicate the ~40 helper lines into
each producer rather than couple them.

### Antigravity adapter: `record-antigravity-session-state.py`

- Reads one JSON payload from stdin; receives the event name as `sys.argv[1]`.
- Maps the event to a state per the table above; ignores unknown events.
- `session_id ← conversationId` (validated: non-empty, no `/`, no leading `.`);
  `cwd ← workspacePaths[0]`; `pid ← resolve_agent_pid(os.getppid())`.
- Target directory `${XDG_STATE_HOME:-~/.local/state}/antigravity-sessions/`.
- Writes via the shared `write_state`, then exits 0.
- Entire body wrapped in `try/except: pass` — a monitor must never break or
  slow `agy` — and **prints `{}` to stdout in a `finally` block**, so the
  antigravity output contract is met even if anything above throws.
- Knows nothing about agent-status-bar; its only obligation is the shared
  state-file contract.

### Registration (`gemini/config/hooks.json`)

Each event is one registration that runs the script with the event name as an
argument. `PreToolUse` and `PostToolUse` are deliberately absent (see the state
model above for why `PostToolUse` must not be hooked).

```json
{
  "record-session-state": {
    "PreInvocation": [
      { "type": "command",
        "command": "python3 $HOME/.gemini/hooks/record-antigravity-session-state.py PreInvocation" }
    ],
    "Stop": [
      { "type": "command",
        "command": "python3 $HOME/.gemini/hooks/record-antigravity-session-state.py Stop" }
    ]
  }
}
```

The global hooks path is registered by symlinking `~/.gemini/config/hooks.json`
→ `dotfiles/gemini/config/hooks.json` and `~/.gemini/hooks` →
`dotfiles/gemini/hooks` (so the `$HOME/.gemini/hooks/...` command resolves).

### Global hooks path — confirmed

The CLI's global hooks path was confirmed empirically (agy 1.1.4): a trivial
`Stop` hook placed at **`~/.gemini/config/hooks.json`** fired on `agy -p "hi"`.
That is the registration location; the plugin form
(`plugins/<name>/hooks.json`) remains an untested fallback.

## Consumer (this repo) — shared multi-agent refactor

The state files are read identically; the only changes are watching two
directories, tagging each snapshot with its agent, and labeling dropdown rows.

### `StateModel.swift`

- Add `enum AgentType: String { case claude, antigravity }`.
- `SessionSnapshot` gains `let agent: AgentType`, **injected by the loader from
  the source directory** — `decode` gains an `agent:` parameter; the JSON is
  unchanged and carries no agent field.
- `SessionRow` gains `agent` so the dropdown can label it.
- `splitStale` returns the stale **snapshots** (not just IDs) so the controller
  can delete each from the correct agent's directory.
- **`evaluate()` needs no agent branching.** In this iteration antigravity never
  produces `permission`, so the existing CPU override (`permission → running`)
  naturally applies to Claude only, and the CPU sampler (already gated on the
  presence of a `permission` session) is untouched. `agent` is used only for
  stale-deletion routing and row labels.

### `main.swift`

- Replace the single `stateDirURL` with an ordered
  `[(agent: AgentType, url: URL)]` (claude → `claude-sessions`, antigravity →
  `antigravity-sessions`) under the same XDG state base.
- Replace the single `dirSource` with one `DispatchSource` per existing
  directory; the 5 s poll retries attaching watchers as directories appear.
- `loadSnapshots()` iterates the directories, decoding each file with its
  directory's `AgentType`, and merges into one flat array.
- Stale cleanup deletes `<agent-dir>/<sessionID>.json` using each stale
  snapshot's `agent`.

### Menu bar and dropdown

- **Bar counts stay aggregated across agents** — running/permission/idle totals
  for the whole machine, preserving the minimal monochrome design. No per-agent
  segments.
- **Dropdown rows carry a short agent tag**, e.g. `agy · my-project` and
  `claude · my-project`, keeping the state glyph and elapsed time as today.
  (Exact tag text finalized in spec review.)

## Config

Unchanged. Alerts are keyed on state, not agent, so antigravity idle uses the
existing `idle_alert_sec` / `sound_idle`. No new keys.

## Testing

- **Swift (XCTest):** merged snapshots from both directories; counts aggregate
  across agents; per-directory stale routing (a stale antigravity file is
  deleted from `antigravity-sessions`, not `claude-sessions`); rows carry the
  correct agent tag; antigravity snapshots never yield a `permission` segment.
- **Python (`unittest`, in dotfiles):** the antigravity adapter maps each
  argv event to the expected state file; `conversationId`/`workspacePaths[0]`
  mapping; `since` preservation on same-state writes; `{}` printed on stdout;
  malformed-payload no-op. Shared-helper tests for `write_state` /
  `resolve_agent_pid`. The existing Claude producer tests must still pass after
  the refactor.
- **Manual E2E:** extend `scripts/fake-session.sh` to also write contract files
  into `antigravity-sessions/`, driving mixed-agent bar and dropdown states
  without a real producer; a real `agy` session in tmux as final verification.

## Error handling and edge cases

- `agy` killed without any stop event: handled by the consumer's existing dead
  PID / 24 h stale sweep (there is no `SessionEnd` to rely on).
- Missing `antigravity-sessions/` directory: the consumer shows the quiet glyph
  and retries the watch; created by the producer on first write.
- Malformed / empty payloads or state files: skipped silently (atomic rename on
  the producer side makes partial files rare); the adapter still prints `{}`.
- Antigravity waiting on a permission dialog: displays as `running`, no alert —
  the documented limitation of the two-state iteration.

## Ownership

Mirrors the Claude split. **Dotfiles own the antigravity producer**
(`gemini/hooks/record-antigravity-session-state.py`, `gemini/config/hooks.json`,
and the shared `agent-session-state/session_state.py`), wired by dotfiles
`setup.sh`; nothing in this repo mutates `~/.gemini`. **This repo owns one
consumer**, reading `antigravity-sessions/` exactly as it reads
`claude-sessions/`. Installing or removing the app never touches dotfiles.

## References

- Antigravity CLI `agy` 1.1.4, embedded "Lifecycle Hooks (`hooks.json`)"
  reference (events, stdin/stdout contract) — current as of 2026-07-18.
- `docs/superpowers/specs/2026-07-18-agent-status-bar-design.md` — the Claude
  Code design this extends.
