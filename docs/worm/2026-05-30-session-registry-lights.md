# WORM Log — Session Registry + Per-Session Lights

**Created:** 2026-05-30 12:42 Europe/Dublin  
**Branch:** `design/session-registry-lights`  
**Repository:** `trjh/TabChroma`  
**Intent:** Append-only record for the menu-bar session indicator design discussion.

## WORM rules for this file

- Treat this file as write-once/read-many: append new entries; do not edit or delete prior entries.
- Corrections should be added as later entries with timestamps and context.
- Design decisions should be mirrored into the design doc when they become current intent.

---

## 2026-05-30 01:28–01:42 — Initial Codex compatibility PR context

A PR was opened to make TabChroma work with OpenAI Codex as well as Claude Code:

- PR: <https://github.com/trjh/TabChroma/pull/4>
- Branch: `codex-compat`
- Changes included:
  - `AGENTS.md` for OpenAI Codex repository guidance.
  - Codex lifecycle hook registration in `~/.codex/hooks.json` during `tab-chroma install`.
  - Codex hook cleanup during uninstall.
  - README/help text updated from Claude-only wording to Claude Code + Codex wording.
- Validation performed:
  - `bash -n tab-chroma.sh install.sh uninstall.sh`
  - `python3 -m json.tool themes/default/theme.json`
  - temp-home install smoke test for generated Claude and Codex hook JSON
  - simulated `UserPromptSubmit` hook event writing `.state.json` as `working`
- After `main` was updated, latest `main` was merged into the PR branch and pushed.

---

## 2026-05-30 02:36 — Brainstorm: minimal/fun status surfaces

User asked what else could be used to minimally and playfully show Claude/Codex session status.

Options discussed:

1. **SwiftBar / xbar**
   - Script-driven menu bar output.
   - Good for showing multiple textual/emoji indicators and a dropdown.
   - Candidate repos:
     - `swiftbar/SwiftBar` (~4k stars at time checked) — powerful macOS menu bar customization tool.
     - `matryer/xbar` (~18k stars at time checked) — script/program output in macOS menu bar.
2. **AnyBar**
   - Simple status light controlled via UDP.
   - Candidate repo:
     - `tonsky/AnyBar` (~6k stars at time checked) — OS X menubar status indicator.
   - Good for one global light; less ideal for one indicator per live session.
3. **Native/polished menu bar app**
   - Inspiration repo:
     - `exelban/stats` (~39k stars at time checked) — macOS system monitor in menu bar.
4. **Pixel pet / tiny character approach**
   - One small animated character per session.
   - Cute but likely a second pass because menu bar space becomes a constraint with many sessions.
   - Small related repo found:
     - `thatbackendguy/RunCat365MacOS` (~17 stars at time checked).
5. **Other surfaces**
   - tmux status segment
   - shell prompt glyph
   - short sounds
   - desktop notifications
   - external lights such as blink(1), Hue, Nanoleaf, WLED, Stream Deck

Recommendation at that time: add a shared status/session registry to TabChroma, then ship a simple SwiftBar/xbar plugin first. Pixel pet/native app can come later.

---

## 2026-05-30 02:41 — Requirement: one element per session

User clarified:

> I’d want one element per session, so if it’s 5 Claude and 2 codex then show me 7 indicators

Implications:

- Avoid AnyBar as the primary UI because it is naturally one global light.
- Use a registry of active sessions so a UI can render N indicators.
- Initial menu bar shape could be a compact row, for example:
  - `C● C● C● C! C✓ X● X!`
  - `C` = Claude, `X` = Codex
  - status glyph/color follows TabChroma tab colors: blue working, green done, orange attention, red permission.
- Dropdown should list session details: agent, label/project, status, cwd, updated time.
- Stale sessions need expiry to avoid indicators accumulating forever.

Draft data model proposed:

```json
{
  "sessions": {
    "claude:abc123": {
      "agent": "claude",
      "status": "working",
      "label": "TabChroma",
      "cwd": "/Users/timh/TabChroma",
      "updated_at": 1780105260
    },
    "codex:def456": {
      "agent": "codex",
      "status": "permission",
      "label": "deploy-ui",
      "cwd": "/Users/timh/deploy-ui",
      "updated_at": 1780105272
    }
  }
}
```

---

## 2026-05-30 12:42 — Current requested design direction

User requested a new branch, WORM log, and design doc. Current desired direction:

1. Start with TabChroma writing a shared session registry.
2. Investigate concurrent updates/race conditions.
   - User explicitly asked whether SQLite is appropriate because it has built-in locking.
3. UI should be simple lights, like the AnyBar example, but one light per active session.
   - Colors should match existing tab colors.
4. Second pass:
   - Get screen geometry from iTerm2.
   - Locate each tab on screen.
   - Determine tab order left-to-right.
   - Arrange lights left-to-right to match the actual visible tab order.
5. Commit and push branch for work in another session.

---

## 2026-05-30 — Design decisions resolved

Picked up the design doc to refine it. Resolved the previously-open product
questions; mirrored into `docs/design/session-registry-lights.md`.

- **DB location:** `~/Library/Application Support/TabChroma/sessions.sqlite3`,
  not under `DATA_DIR`. App-neutral, shared across Claude + Codex, survives
  plugin reinstall. Writer must `mkdir -p` it; uninstall should not implicitly
  `rm -rf` it. Add a `TAB_CHROMA_REGISTRY_DB` override for tests.
- **`done` visibility:** stays green **until the session/terminal exits**, not on
  a short timer. `expires_at` becomes a *fallback backstop* (working/permission/
  attention: 2 h; done: 12 h; session.start: 10 min) rather than the primary
  lifecycle signal.
- **Explicit session end:** **brief afterglow** — on `SessionEnd` set a neutral/
  green state and `expires_at = now + 60s`, let the normal prune pass remove it.
  No separate timer needed.
- **Codex session-end signal:** **none exists.** Verified the installer registers
  no `SessionEnd` (nor `Notification`) hook for Codex (`tab-chroma.sh:463`);
  only Claude gets them (`:462`). So Codex sessions rely on the TTL backstop, and
  `attention` is Claude-only. The renderer must not assume every agent produces
  every state.
- **Menu bar crowding:** **collapse past a threshold** (default 8). At/below the
  threshold, one light per session (the original requirement); above it, group by
  `(agent, state)` with a count (`C🔵×5 X🔴×2`). The dropdown always lists every
  session individually regardless of collapse.

Net effect: Phase 1 (registry writer) is unblocked. The one thing to verify
during Phase 1 is whether the Codex `session_id` is stable across a session's
hook events, which determines whether the composite fallback key is needed.

---

## 2026-05-30 — Phase 1 implemented

Implemented the registry writer inline in `tab-chroma.sh`:

- `REGISTRY_DB` (Application Support, `TAB_CHROMA_REGISTRY_DB` override). The
  hook's existing single `python3` block now upserts a `sessions` row at the
  end, fully wrapped in `try/except` with no stdout, so it can never break the
  hook. TTL backstops: working/permission/attention 2h, done 12h, starting
  10min, ended (SessionEnd afterglow) 60s; expired rows pruned on each write.
- Installer tags hook commands with `TAB_CHROMA_AGENT=claude`/`=codex`; reinstall
  upgrades old untagged entries and de-dupes (collapse-to-one logic). Uninstall
  needle-matching still removes the tagged commands; uninstall now leaves the
  shared registry in place and prints how to remove it.
- Added `tab-chroma sessions [list|prune|clear|path]`.

Two lessons recorded for future work:

1. **bash 3.2 command-substitution apostrophe bug.** The hook's Python lives
   inside `eval "$(... python3 - << 'PYEOF' ... )"`. macOS `/bin/bash` (3.2)
   naively counts apostrophes across the heredoc body when scanning `$(...)`, so
   an *odd* number of stray apostrophes (e.g. a contraction in a comment) yields
   an "unexpected EOF" parse failure at runtime — even though `bash -n` under
   bash 5 reports OK. Rule: avoid lone apostrophes inside that block and always
   syntax-check with `/bin/bash -n`, not just `bash -n`.
2. **`uninstall` deletes `DATA_DIR`, which defaults to the repo.** In a plain
   git checkout `DATA_DIR == SCRIPT_DIR == repo`, so running `tab-chroma
   uninstall` from the dev tree `rm -rf`'d the working copy. This is correct
   behavior for a real self-contained install, but a dangerous footgun in dev.
   Recovered by re-cloning from `origin` (design commits were pushed) and
   re-applying the uncommitted Phase 1 edits. Rule: only ever exercise
   install/uninstall with `TAB_CHROMA_DATA` pointed at a throwaway dir.

Validated under `/bin/bash 3.2`: hook simulation across all states, SessionEnd
afterglow + prune-on-write, TTL values, installer upgrade/idempotency/no-dupes,
and the `sessions` CLI. Codex `session_id` stability against real payloads is
still the open item to confirm before relying on the non-composite key.

