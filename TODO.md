# agent-status-bar — OSS launch checklist

Maintainer roadmap for releasing and growing this as an open-source project.
This project is **free / OSS, supported by optional donations** — no Mac App
Store and no paid distribution planned.

**Status:** published public at <https://github.com/mkuri/agent-status-bar>
(personal `mkuri` account). `main` at `1dcb8d2`, 44/44 Swift tests green.

Legend: `⚑` needs a maintainer decision · items without it are mechanical.

## Done
- [x] Merge "quieter alerts" to `main` (D1 silent first sighting, D2 `sound_cooldown_sec` nag throttle, D3 permission threshold 120→300)
- [x] Create public GitHub repo and push `main` (`mkuri/agent-status-bar`)
- [x] Pre-publish secret scan of tracked files (clean)
- [x] Add a LICENSE (**MIT**, `Copyright (c) 2026 Makoto Kurihara`)

## Now (highest leverage)
- [ ] **Ship / document the producer.** The app only shows real data once the state-file hooks are installed; without them it just renders a dimmed terminal glyph. Add a `producer/` directory (or a docs page) with a copy-pasteable setup: the Claude hook (`record-session-state.py` + the `hooks` block for `settings.json`) and the Antigravity producer (`record-antigravity-session-state.py` + `hooks.json`). These currently live only in the maintainer's private dotfiles. This is required for any external user to get the app working.
- [ ] **README: add a demo GIF and full install steps.** A short screen recording of the menu bar + dropdown (capture with ⌘⇧5) is the single most effective addition for a menu-bar app. Document requirements (macOS 13+, Apple Silicon), build, login-item setup, and the producer setup above.
- [ ] **Set repo topics** for discoverability: `macos`, `menu-bar`, `swift`, `claude-code`, `developer-tools`.
- [ ] **⚑ Consider the project / repo name.** `agent-status-bar` is clear but generic, and the tool is now multi-agent (Claude + Antigravity) — keep any new name agent-agnostic (avoid `claude` in it). Renaming the GitHub repo is cheap and reversible (GitHub auto-redirects old URLs), so this can wait; but settle it **before** the sticky commitments lock in: the bundle id (`dev.mkuri.agentstatusbar`) and any Homebrew cask token (see Later). Candidate directions: AgentBar, SessionBar, Perch, Roost.

## Soon (trust + contributors)
- [ ] **⚑ `.github/FUNDING.yml`** pointing at GitHub Sponsors (enable Sponsors on the `mkuri` account first) and/or Ko-fi / Buy Me a Coffee. Adds a "Sponsor" button to the repo.
- [ ] **CI:** GitHub Actions running `swift build` + `swift test` on a macOS runner for pull requests; add a status badge to the README.
- [ ] **CONTRIBUTING.md:** how to build/test (`cd StatusBarApp && swift build && swift test`) and the producer↔consumer split (state files are the contract).
- [ ] Issue and PR templates; `SECURITY.md` with a report contact; optionally `CODE_OF_CONDUCT.md` (Contributor Covenant).

## Later (reduce install friction = adoption)
- [ ] **Release workflow:** on a SemVer tag, `swift build -c release`, zip the binary, attach to a GitHub Release. Gives non-builders a download.
- [ ] **Gatekeeper note:** document the unsigned-binary workaround (right-click → Open, or `xattr -d com.apple.quarantine`). Notarization (Developer ID, ~$99/yr) is optional and only worth it if the project gets popular.
- [ ] **Homebrew cask** via a `mkuri/homebrew-tap` (`brew install --cask mkuri/tap/agent-status-bar`) once a release binary exists — the biggest convenience win for macOS developers.
- [ ] **Proper `.app` bundle** with `CFBundleIdentifier = dev.mkuri.agentstatusbar`. This fixes the bundle id before wide distribution (changing it later fragments users' settings/LaunchAgents).

## Ongoing
- [ ] SemVer tags + a CHANGELOG; triage issues; keep a short public roadmap.

## Decisions / notes
- **Identity:** personal `mkuri`, not the cloveclove.dev business, for this scale. The repo is trivially transferable to a `cloveclove` org later (GitHub redirects old URLs) if it ever commercializes.
- **Monetization:** OSS + optional donations only. No App Store, no paid sales.
- **Future bundle id** (only when notarizing/distributing a `.app`): `dev.mkuri.agentstatusbar` (owns `mkuri.dev`; no homepage yet).
- **Out of scope:** suppressing the nag only while the user is typing into that specific session — needs fragile per-session terminal-pane focus that breaks the terminal-agnostic design; revisit as an opt-in only if requested.

---
*Resume in a new chat:* read this file, the design docs in `docs/superpowers/specs/`, and (if present locally) `.superpowers/sdd/progress.md` — a gitignored maintainer scratch log with the full build history.
