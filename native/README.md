# TabChroma Lights — native menu-bar app

A compact native macOS menu-bar app that shows **one status light per active
Claude Code / Codex session**, read from the TabChroma shared SQLite registry.
It is the successor to the SwiftBar plugins in `extras/swiftbar/` — no plugin
host, no streamable-protocol/SwiftBar-version quirks, fully event-driven.

```
🔴 🟠 🔵 🟢
```

The light colors follow TabChroma's semantic states (working 🔵, done 🟢,
attention 🟠, permission 🔴, starting ⚪, ended ⚫); past a threshold the bar
collapses to grouped counts (`🔵×5 🔴×2`). Clicking the item drops down a list
of every session (colored, with age); clicking a session **focuses its iTerm2
pane** by reusing the existing `tab-chroma sessions focus <key>` CLI.

## Why native (vs the SwiftBar plugins)

Live testing showed SwiftBar's *streamable* plugin support only renders on
SwiftBar ≥ 2.1.0 (the brew stable, 2.0.1, creates the item hidden). The native
app sidesteps that entire class of host problems — version gates, status-item
auto-hiding, `__pycache__`, etc. — and is genuinely small.

## Build

One Swift file, compiled directly — no Xcode project, no `.app` bundle, no
dependencies beyond the macOS SDK:

```bash
cd native
make            # swiftc -swift-version 5 -O -framework AppKit main.swift -o tabchroma-lights
./tabchroma-lights      # or: make run
make test       # compile and run the non-GUI self-test
```

It runs as a menu-bar *agent* (`NSApplication` activation policy `.accessory`):
no Dock icon, no window.

## Configuration (env vars, same as the SwiftBar reader)

| Variable | Default | Purpose |
|---|---|---|
| `TAB_CHROMA_REGISTRY_DB` | `~/Library/Application Support/TabChroma/sessions.sqlite3` | Registry path. |
| `TAB_CHROMA_LIGHTS_COLLAPSE` | `8` | Collapse the bar to grouped counts past this many sessions (`0` disables). |
| `TAB_CHROMA_BIN` | auto-detected | Path to `tab-chroma.sh` for focus/prune (auto: `~/.claude/hooks/tab-chroma/tab-chroma.sh` or `PATH`). |

## How it works

- Reads the registry **read-only** (`mode=ro`), so it never locks the hook writers.
- Watches the registry's mtime (incl. `-wal`/`-shm`) on a lightweight 0.5 s
  in-process timer and re-renders the menu-bar title only when it changes — none
  of the SwiftBar poll plugin's per-tick python respawn cost.
- The dropdown is rebuilt fresh each time it opens, so session ages stay current.

## Status & next steps

Initial working checkpoint — lights render, update live, and click-to-focus works.
Planned polish:

- Wrap in a minimal `.app` bundle + a Login Item so it auto-starts at login.
- Replace the 0.5 s mtime poll with an FSEvents watch (truly idle-cost-free).
- Idle state: dim the `○`.
- Optional: agent-prefix mode (`C`/`X`) and per-window ordering (Phase 5 parity).
