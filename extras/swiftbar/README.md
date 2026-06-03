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
state, age) with its working directory and session id. **Click a session row to
raise iTerm2 and focus the tab/session it belongs to**. The dropdown also has
actions to refresh, prune dead sessions, clear the registry, and open the
registry folder.

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

**Copy** the plugin into your SwiftBar/xbar plugin folder (find the exact path
in SwiftBar Preferences → "Plugin Folder", or xbar preferences):

```bash
# SwiftBar (adjust the destination to your configured Plugin Folder):
cp extras/swiftbar/tab-chroma-sessions.1s.py \
  ~/Library/Application\ Support/SwiftBar/Plugins/
chmod +x ~/Library/Application\ Support/SwiftBar/Plugins/tab-chroma-sessions.1s.py
```

Then **fully quit and relaunch** SwiftBar (or xbar) so it rescans the folder.
The light appears in the menu bar within ~1 second.

> **Why copy, not symlink?** SwiftBar does not reliably pick up *symlinked*
> plugins — a symlink may be silently skipped until you fully relaunch SwiftBar,
> and on some versions never loads. A plain copy always works. The tradeoff is
> that you must re-copy the file after pulling repo updates.

If the light never shows up even though `./tab-chroma-sessions.1s.py` prints
output in a terminal, the usual cause is a **full menu bar** hiding the icon
under the notch — make room (or use a menu-bar manager like Ice/Bartender) and
relaunch SwiftBar.

The `.1s.py` in the filename is the **refresh interval** (1 second). To poll
less often, rename the copy, e.g. `tab-chroma-sessions.2s.py` or `.5s.py`.

## Streaming variant (experimental)

`tab-chroma-sessions-stream.1h.py` is a **streamable** SwiftBar plugin that
replaces poll-and-respawn with a single resident process: it watches the
registry file's mtime and pushes an update only when the registry actually
changes, so lights flip ~immediately with near-zero idle cost — instead of
cold-starting python3 every second. It reuses the standard reader's rendering
verbatim (it imports `tab-chroma-sessions.1s.py`), so the two never diverge in
how a session is drawn.

To try it, copy **both** files into your Plugins folder (they must sit side by
side so the import resolves) and enable **only one** of the two in SwiftBar so
you don't get two menu-bar items:

```bash
cp extras/swiftbar/tab-chroma-sessions.1s.py \
   extras/swiftbar/tab-chroma-sessions-stream.1h.py \
   ~/Library/Application\ Support/SwiftBar/Plugins/
chmod +x ~/Library/Application\ Support/SwiftBar/Plugins/tab-chroma-sessions*.py
```

It is a prototype: SwiftBar's streamable separator protocol has varied across
versions, so if the menu shows literal `~~~` lines or never updates, your build
doesn't support it the way this expects — just use the standard
`tab-chroma-sessions.1s.py` instead. Tunables: `TAB_CHROMA_STREAM_POLL`
(mtime-check cadence, default 0.25s) and `TAB_CHROMA_STREAM_HEARTBEAT` (force a
redraw at least this often so dropdown ages stay fresh, default 5s).


## Focus iTerm2 from a session row

Each active session row is clickable. Selecting it runs:

```bash
tab-chroma sessions focus <session_key>
```

TabChroma reads the shared registry, looks up the resolved tty path recorded by
the hook (`tty_device`, e.g. `/dev/ttys003`), activates iTerm2, and asks iTerm2
to select the window/tab/pane on that tty.

This is best-effort:

- iTerm2 must be running. The **first** click usually triggers a macOS prompt to
  let SwiftBar control iTerm — allow it (System Settings ▸ Privacy & Security ▸
  Automation ▸ SwiftBar ▸ iTerm). The very first focus can take a second or two,
  so give it a moment before assuming it failed.
- When focus *fails* (iTerm control still blocked, or the tab was closed), the
  click is not silent: TabChroma posts a macOS notification and, for a blocked
  permission, tells you exactly where to grant it. A successful focus just makes
  iTerm jump to the tab — no notification.
- Matching is strongest for ordinary iTerm2 tabs/panes because the registry
  stores the resolved tty path, e.g. `/dev/ttys003`.
- A session only becomes focusable once it has recorded a tty — i.e. after at
  least one hook fires under the current build. A long-idle session from before
  an upgrade shows up but only raises iTerm until its next activity refreshes it.
- If several agent sessions share one terminal through tmux or similar, focusing
  can only raise that shared terminal session.
- If no exact match is found, TabChroma still activates iTerm2 so you are close
  to the right place.

You can test a row manually with:

```bash
tab-chroma sessions list
tab-chroma sessions focus '<session_key-from-list>'
```

## Configuration

The plugin reads these environment variables (set them in SwiftBar's plugin
environment, or export them where SwiftBar can see them):

| Variable | Default | Purpose |
|---|---|---|
| `TAB_CHROMA_REGISTRY_DB` | `~/Library/Application Support/TabChroma/sessions.sqlite3` | Registry database path (must match the writer). |
| `TAB_CHROMA_LIGHTS_AGENT_PREFIX` | `off` | Prefix each circle with the agent letter (`C`=Claude, `X`=Codex), e.g. `C🔵 X🟢`. Off by default (just circles). Set to `1`/`true`/`yes`/`on` to enable. |
| `TAB_CHROMA_LIGHTS_COLLAPSE` | `8` | Above this many sessions, collapse the menu bar to grouped counts (`🔵×5 🔴×2`, or `C🔵×5 X🔴×2` with the agent prefix on); the dropdown still lists each session. `0` disables collapsing. |
| `TAB_CHROMA_BIN` | auto-detected | Path to `tab-chroma.sh` used by the Prune/Clear actions. Auto-detected from `~/.claude/hooks/tab-chroma/tab-chroma.sh` or `PATH`; if not found, those actions are hidden. |

## Notes

- The plugin opens the registry **read-only** (`mode=ro`), so it never creates,
  writes, or locks the database and cannot race the hook writers.
- Sessions are pruned from the registry by the hook writers (and by the
  Prune/Clear actions here), not by this reader. The reader simply hides rows
  that are not live (`expires_at < now`); live PID-anchored rows carry
  `expires_at = NULL` and always show.
- **Lights do not expire on inactivity.** A session stays lit for as long as its
  agent process is alive — closing the laptop for the weekend leaves every
  still-running session shown. Rows are removed only when the hook writer's (or
  Prune's) liveness sweep finds the process gone: a clean exit (`SessionEnd`), a
  crash, or a closed tab. Because the sweep runs on hook writes, a dead session
  may linger until the next event from any session, then disappear; Prune forces
  it immediately. See `docs/design/session-registry-lights.md` (Phase 4).
- Codex sessions have no clean end signal, but a finished-yet-running Codex
  session is still a live process, so it correctly stays 🟢 until you exit it
  (or Prune). Only the PID-less fallback rows still rely on the 12-hour TTL.
