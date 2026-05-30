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

