# TabChroma Session Lights (SwiftBar / xbar)

A menu-bar plugin that shows **one status light per active Claude Code / Codex
session**, read from the TabChroma shared session registry.

```
C🔵 C🟢 X🔴
```

`C` = Claude, `X` = Codex. The light color follows TabChroma's semantic states:

| Light | State |
|---|---|
| 🔵 | working |
| 🟢 | done |
| 🟠 | attention |
| 🔴 | permission |
| ⚪ | starting (session just began) |
| ⚫ | ended (brief afterglow before the row is pruned) |

Clicking the menu-bar item drops down a list of every session (agent, label,
state, age) with its working directory and session id, plus actions to refresh,
prune expired sessions, clear the registry, and open the registry folder.

## Prerequisites

1. TabChroma installed with the Phase 1 registry writer (run `tab-chroma install`).
   The plugin reads the registry that the hooks populate; with no active
   sessions it shows a dim `○`.
2. **SwiftBar** (recommended) or **xbar**:
   ```bash
   brew install swiftbar      # or: brew install xbar
   ```
3. `python3` on `PATH` (the macOS Command Line Tools python3 is fine; the plugin
   uses only the standard library).

## Install

Symlink (so updates to the repo copy are picked up automatically) the plugin
into your SwiftBar/xbar plugin folder:

```bash
# SwiftBar: Preferences → "Plugin Folder" shows the path; commonly:
ln -s "$PWD/extras/swiftbar/tab-chroma-sessions.1s.py" \
  ~/Library/Application\ Support/SwiftBar/Plugins/

# xbar: plugin folder is set in xbar preferences, commonly:
ln -s "$PWD/extras/swiftbar/tab-chroma-sessions.1s.py" \
  ~/Library/Application\ Support/xbar/plugins/
```

Then refresh plugins in SwiftBar/xbar (or just relaunch it). The light appears
in the menu bar within ~1 second.

The `.1s.py` in the filename is the **refresh interval** (1 second). To poll
less often, copy/rename it, e.g. `tab-chroma-sessions.2s.py` or `.5s.py`.

## Configuration

The plugin reads these environment variables (set them in SwiftBar's plugin
environment, or export them where SwiftBar can see them):

| Variable | Default | Purpose |
|---|---|---|
| `TAB_CHROMA_REGISTRY_DB` | `~/Library/Application Support/TabChroma/sessions.sqlite3` | Registry database path (must match the writer). |
| `TAB_CHROMA_LIGHTS_COLLAPSE` | `8` | Above this many sessions, collapse the menu bar to grouped counts (`C🔵×5 X🔴×2`); the dropdown still lists each session. `0` disables collapsing. |
| `TAB_CHROMA_BIN` | auto-detected | Path to `tab-chroma.sh` used by the Prune/Clear actions. Auto-detected from `~/.claude/hooks/tab-chroma/tab-chroma.sh` or `PATH`; if not found, those actions are hidden. |

## Notes

- The plugin opens the registry **read-only** (`mode=ro`), so it never creates,
  writes, or locks the database and cannot race the hook writers.
- Sessions are pruned from the registry by the hook writers (and by the
  Prune/Clear actions here), not by this reader. The reader simply hides expired
  rows (`expires_at < now`).
- Codex sessions have no clean end signal, so a finished Codex session shows 🟢
  until its 12-hour fallback TTL elapses (or you Prune/Clear). This is expected;
  see `docs/design/session-registry-lights.md`.
