# Linux status bar

Status: Approved

Related issue: [#8](https://github.com/mkuri/agent-status-bar/issues/8)

A Go consumer that renders agent session state on the GNOME top bar, with
feature parity to the macOS menu bar consumer. Peer of `macos-status-bar/`;
both read the same state-file contract described in
`../superpowers/specs/2026-07-18-agent-status-bar-design.md`.

## Context

The repository ships a producer (`session-state-recorder/`, stdlib Python) and,
until now, a single consumer (`macos-status-bar/`, Swift/AppKit). The producer
is already portable: it uses only stdlib Python and XDG paths, its test suite
passes on Ubuntu 22.04, and it writes live state files there. A Linux machine
therefore has a working producer and no consumer at all.

This document covers only the new consumer. The producer, the state-file
contract, and the alert semantics are unchanged.

## Goals

- Parity with the macOS consumer: machine-wide `running` / `permission` /
  `idle` counts visible at a glance, entry sounds, past-threshold nags with
  cooldown, blink while over threshold, and a dropdown listing every session.
- One shared configuration file across both platforms.
- One shared source of truth for the alert-engine spec, so the two consumers
  cannot silently diverge.
- No change to the producer.

## Non-goals

- **Desktop notifications.** The macOS consumer has none; sound plus a visible
  bar is the whole alerting surface. Keeping the two consumers identical here
  avoids a permanent spec fork.
- **Rewriting the macOS consumer in Go.** `fyne.io/systray` supports macOS, so
  a single-binary two-platform consumer is technically possible, but replacing
  a working, published Swift app is out of scope.
- **Tightening the gap between panel indicators.** The spacing comes from the
  shell theme (see D3); changing it affects every indicator on the user's
  panel and breaks on GNOME upgrades.
- Supporting desktops without an SNI host (see Consequences).

## Measured constraints

Every decision below rests on measurements taken on the target host
(Ubuntu 22.04.5, GNOME Shell 42.9, Wayland, `ubuntu-appindicators@ubuntu.com`
enabled, scale factor 1.0). They are recorded because several of them
contradict the obvious design.

1. **The panel forces tray icons into a square.** `indicatorStatusIcon.js` sets
   only the height (`this._icon.set_height(iconSize * scaleFactor)`), and
   `appIndicator.js` derives `icon_size` from the pixmap *width*. A 61×22
   composite collapsed to an unreadable sliver. The macOS approach — compositing
   glyphs and counts into one wide template image — is therefore impossible.
2. **`XAyatanaLabel` renders real text on the panel.** The extension adds the
   property dynamically (`_addExtraProperty`) even though its interface XML has
   it commented out, and `_updateLabel()` puts it in the panel box as an
   `St.Label`. Verified working: the label appeared beside the icon in the
   shell's own font and updated live.
3. **A tray item is invisible without a menu path.** `_checkIfReady()` requires
   `hasNameOwner && id && menuPath`, and `get menuPath()` maps the conventional
   `/NO_DBUSMENU` sentinel to `null`. Any *other* path string satisfies the
   check, so a dbusmenu implementation is **not** required to display an icon —
   only to make the dropdown work.
4. **Each tray item is its own panel button.** The shell theme sets
   `#panel .panel-button { -natural-hpadding: 12px }`, so N items introduce
   N−1 gaps of ~24px.
5. **Blinking by icon replacement is free.** Swapping the icon every 500 ms for
   45 s produced exactly 90 swaps with no drops, 0.9% CPU and 12 MB RSS in the
   app; gnome-shell's own CPU was 3.80% during the run against a 4.40%
   baseline, i.e. the added cost is below measurement noise.
6. **Effective icon size is 16 px** (`Panel.PANEL_ICON_SIZE` on GNOME 42 at
   scale 1.0). A single 22×22 pixmap was downscaled and lost detail.
7. **Label symbol availability differs.** `▶` (U+25B6) and `✓` (U+2713) resolve
   to DejaVuSans — monochrome and effectively ubiquitous. `✋` (U+270B) exists
   only in FreeSerif and NotoColorEmoji, and the shell picks the colour emoji.
8. **`fyne.io/systray` cannot express this design.** It never sets
   `XAyatanaLabel`, and its state is a package-level singleton
   (`var instance = &tray{...}`), so one process can own only one item.

## Decision

### D1 — Custom StatusNotifierItem over godbus

Implement `org.kde.StatusNotifierItem` directly on
`github.com/godbus/dbus/v5` rather than using `fyne.io/systray`, which cannot
set `XAyatanaLabel` (measurement 8) — the property the whole layout depends on.

Despite the `org.kde.` namespace this is the portable choice: gnome-shell
itself owns `org.kde.StatusNotifierWatcher`, and the same protocol serves KDE
Plasma, Xfce and wlroots panels.

Dependencies stay minimal: `godbus/dbus/v5` for the bus and
`golang.org/x/image` for glyph rasterisation.

### D2 — One tray item: square icon plus a text label

A single SNI item whose icon is one Font Awesome glyph and whose
`XAyatanaLabel` carries every non-zero count as text:

```
[✋] ▶2 ✋1 ✓3
 |    |
 |    XAyatanaLabel — shell font, sharp at any scale
 square icon — the most urgent state present
```

The icon glyph reflects the most urgent state present, in the order
`permission` > `idle` > `running` > none, using the Font Awesome codepoints
that correspond to the macOS SF Symbols: `f04b` play (`play.fill`), `f256`
hand-paper (`hand.raised.fill`), `f00c` check (`checkmark.circle`), `f120`
terminal for the dimmed no-session state.

`IconPixmap` carries 16/22/32/48 px renderings, each rasterised natively at
that size rather than scaled from one bitmap, so the panel picks a crisp one
(measurement 6).

Counts are text, not pixels. This is strictly better than the macOS approach:
the shell draws them in the interface font, so they stay sharp under any
scaling, and no glyph metrics work is needed.

### D3 — One item rather than one per state

Three items (`[▶]2 [✋]1 [✓]3`) were built and reviewed on the panel. They work,
and they allow blinking a single state's icon, but each item carries its own
12 px padding either side (measurement 4), leaving ~24 px of dead space between
groups. The single-item layout was preferred on review for compactness.

### D4 — Blink replaces the icon only

While any session is over threshold, the icon alternates between full and 25%
alpha every 500 ms; the label stays static.

Blinking part of the label instead (rewriting `✋1` to `✋ `) was built and
rejected on review: the label is proportional text, so blanking a digit shifts
the icon and the remaining counts sideways. Icon-only blink is enough to answer
"does something need me?", which is the blink's whole purpose.

### D5 — Configuration shared with macOS, Linux-only keys added

Both consumers read `~/.config/agent-status-bar/config.json`. Thresholds,
`blink` and `sound_cooldown_sec` are platform-neutral and apply verbatim. Only
the sound defaults differ, because macOS sound names do not exist on Linux:

| Key | macOS default | Linux default |
| --- | --- | --- |
| `sound_permission` | `Glass` | `message` |
| `sound_idle` | `Tink` | `complete` |

Linux-only keys, all optional:

| Key | Default | Meaning |
| --- | --- | --- |
| `icon_font` | bundled Font Awesome | path to a glyph font; `~` expanded |
| `icon_running` / `icon_permission` / `icon_idle` / `icon_empty` | `f04b` / `f256` / `f00c` / `f120` | glyph for each state |
| `label_format` | `▶{running} ✋{permission} ✓{idle}` | label template; zero-count states are dropped |

`label_format` exists because of measurement 7: `✋` depends on an emoji or
FreeSerif font being installed, so a host without either can fall back to a
DejaVu-safe symbol such as `‖`. The macOS `Config` parser ignores unknown keys,
so sharing the file needs no change on that side.

### D6 — Sound via the desktop's own players

The config value decides the mechanism: a value containing `/` or ending in a
known audio extension is a file path played with `paplay`; anything else is a
freedesktop sound-theme event name played with `canberra-gtk-play -i`, falling
back to resolving the event within the theme directory and playing it with
`paplay`. An empty string disables that sound, as on macOS.

### D7 — dbusmenu for the dropdown

The session list requires implementing `com.canonical.dbusmenu`. Per
measurement 3 this is not needed to show the icon, so it is a self-contained
piece of work: the icon and alerts function before it exists, and it can land
without touching the alert engine. `Menu` advertises the real menu path.

### D8 — inotify plus a 5 s poll

`fsnotify` watches each state directory; a 5 s poll handles what events cannot:
threshold expiry, process-death detection, and re-attaching watches to
directories that do not exist yet. The producer writes atomically via
`os.replace`, so the event that matters is `IN_MOVED_TO` — not
`IN_CLOSE_WRITE`.

### D9 — Shared scenario vectors as the spec

The 26 `evaluate()` tests in `StateModelTests.swift` are translated into JSON
scenarios under `testdata/scenarios/`, and both consumers execute all of them.
The Swift per-case tests are replaced by one vector-running test; `formatElapsed`,
`splitStale` and `splitSuperseded` keep their native tests.

Vectors state sound names explicitly rather than relying on defaults, since
those defaults are platform-specific (D5).

### D10 — Toolchain and autostart

Go 1.26.6, installed under `~/sdk/go1.26.6` and referenced by absolute path
from the `Makefile`. The distribution's `/usr/bin/go` (1.18.1, EOL) and the
`golang` apt package are left untouched, and `PATH` is not modified.

Autostart is a `systemd --user` unit bound to `graphical-session.target`, the
counterpart of the macOS LaunchAgent, so the process starts after gnome-shell
and the session bus exist and restarts on failure.

## Alternatives considered

- **Composite one wide image, as on macOS.** Impossible; the panel squashes
  non-square icons (measurement 1). This is what motivated everything else.
- **Three items, one per state.** Built and reviewed; rejected for panel
  padding (D3).
- **Square icon only, counts in the dropdown.** Would keep `fyne.io/systray`
  and cut roughly 400 lines, but loses the at-a-glance count that is the
  point of the tool.
- **A GNOME Shell extension in JavaScript.** Would draw text on the panel
  natively and look closest to macOS, but splits the tool into a Go daemon plus
  a JS extension and adds per-GNOME-version compatibility maintenance.
- **Desktop notifications instead of a bar.** Considered first and rejected: a
  visible bar was wanted, and notifications would fork the spec from macOS.
- **Pinning `fyne.io/systray` v1.10.0 to keep apt Go 1.18.** Only relevant
  while systray was still a candidate; superseded by D1.

## Consequences

- **An SNI host is required.** On GNOME this means the
  `ubuntu-appindicators` extension: enabled by default on Ubuntu, a manual
  install on vanilla GNOME. Without it the app runs and still plays sounds,
  but nothing appears on the panel. The README must say so.
- **`✋` rendering depends on the host's fonts** (measurement 7); `label_format`
  is the escape hatch.
- **The alert spec now lives in JSON.** Changing behaviour means editing the
  vectors and both implementations; CI enforces the pairing.
- **Two consumer implementations to maintain.** Accepted deliberately: the
  vectors cover the part where divergence would actually hurt, and the
  platform layers are genuinely different.
- **We implement two DBus protocols by hand** (SNI and dbusmenu) instead of
  calling a library. This is the cost of `XAyatanaLabel`.
- Panel padding around the single item is not ours to control (D3).

## Deferred work

- **HiDPI.** Only scale factor 1.0 was measured. Multi-resolution pixmaps
  (D2) should cover 2.0, but this is unverified.
- **Antigravity and Codex hooks on Linux.** Not installed on the development
  host, so those two agents are exercised only through
  `scripts/fake-session.sh`. The consumer reads all three contract directories
  regardless.
- **Non-GNOME panels.** The protocol is shared, but only GNOME 42.9 was
  measured; KDE, Xfce and Waybar are untested.

## References

- Issue [#8](https://github.com/mkuri/agent-status-bar/issues/8)
- State-file contract: `../superpowers/specs/2026-07-18-agent-status-bar-design.md`
- Alert semantics being mirrored: `../superpowers/specs/2026-07-19-quieter-alerts-design.md`
- Event-only state evaluation: `../superpowers/specs/2026-07-21-event-only-activity-design.md`

## Decision log

- **2026-08-18** — Initial version (#8). Written after a throwaway spike on the
  target host that overturned three assumptions made before measuring: that a
  wide composited icon was possible (it is not — measurement 1), that
  `fyne.io/systray` would suffice (it cannot set `XAyatanaLabel` and is a
  singleton — measurement 8), and that a dbusmenu implementation gated icon
  display (it does not — measurement 3). The spike also settled the blink
  question empirically (measurements 5 and D4) and chose the single-item
  layout over three items on visual review (D3).
