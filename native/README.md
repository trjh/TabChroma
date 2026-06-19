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

## Install & run at login (recommended)

There is no `.app` bundle or Login Item yet, so the cleanest way to auto-start
the bare executable is a `launchd` **LaunchAgent**. `make install` does the whole
thing: it copies the binary to a stable location *outside* the repo working tree
(so a `make clean`, rebuild, or branch switch never pulls the running binary out
from under launchd), generates the LaunchAgent plist from
`com.tabchroma.lights.plist.in`, and loads it.

```bash
cd native
make install                          # installs to ~/.local/bin by default
# or pick your own stable dir:
make install BINDIR=~/bin
```

`make install` is idempotent — re-run it after editing `main.swift` and it
rebuilds, reinstalls, and reloads the agent in one step. `make uninstall`
unloads the agent, removes the plist, and deletes the installed binary.

To pass config (see the table below), add an `EnvironmentVariables` dict to the
installed plist (there's a commented example in `com.tabchroma.lights.plist.in`)
and re-load it.

### Managing the agent

```bash
# Is it running?  (col 1 = PID — a "-" means it failed to start; col 2 = last exit status)
launchctl list | grep tabchroma

# Stop / disable (won't run at login) and start / re-enable
launchctl unload ~/Library/LaunchAgents/com.tabchroma.lights.plist
launchctl load -w ~/Library/LaunchAgents/com.tabchroma.lights.plist

# Logs
cat /tmp/tabchroma-lights.log /tmp/tabchroma-lights.err
```

## Configuration (env vars, same as the SwiftBar reader)

| Variable | Default | Purpose |
|---|---|---|
| `TAB_CHROMA_REGISTRY_DB` | `~/Library/Application Support/TabChroma/sessions.sqlite3` | Registry path. |
| `TAB_CHROMA_LIGHTS_COLLAPSE` | `8` | Collapse the bar to grouped counts past this many sessions (`0` disables). |
| `TAB_CHROMA_LIGHTS_AGENT_PREFIX` | off | Prefix each light with its agent letter (`C🔵 X🟢`); collapsed counts then group by agent+state. Accepts `1`/`true`/`yes`/`on` (case-insensitive). Useful for mixed Claude+Codex setups. This is the *default*; the **"Agent letters (C/X)" dropdown toggle** overrides it at runtime (persisted in `UserDefaults`). |
| `TAB_CHROMA_BIN` | auto-detected | Path to `tab-chroma.sh` for focus/prune (auto: `~/.claude/hooks/tab-chroma/tab-chroma.sh` or `PATH`). |

## How it works

- Reads the registry **read-only** (`mode=ro`), so it never locks the hook writers.
- Polls the registry's mtime (incl. `-wal`/`-shm`) on a lightweight 0.5 s timer
  and re-renders the menu-bar title only when it actually changes — the `stat()`
  is negligible and a SQLite read happens only on a real change, with none of the
  SwiftBar poll plugin's per-tick python respawn cost. (An FSEvents push was
  tried, but in-place SQLite/WAL writes did not reliably deliver events, so the
  simple timer is the mechanism.)
- When idle (no sessions), the `○` is dimmed so it recedes into the menu bar.
- The dropdown is rebuilt fresh each time it opens, so session ages stay current.
- Two persisted dropdown toggles (`UserDefaults`): **Agent letters (C/X)** prefixes
  each light and row with its agent letter (overrides `TAB_CHROMA_LIGHTS_AGENT_PREFIX`);
  **Show tty & pid** appends `pid <pid>  <tty>` to each row.

## Status & next steps

Lights render, update live, dim when idle, collapse past a threshold, and
**order left-to-right to match the iTerm2 tab layout** (Phase 5; the app runs
`tab-chroma sessions order` on a debounced timer). Click-to-focus works and is
confirmed interactively for both Claude and Codex sessions; auto-start at login
is handled by `make install`. The agent-prefix mode (`C`/`X`) is available via
`TAB_CHROMA_LIGHTS_AGENT_PREFIX`.

The `C`/`X` agent prefix is also a persisted dropdown toggle ("Agent letters
(C/X)"), not only an env var. Planned polish (see the Roadmap in
`docs/design/session-registry-lights.md`):

- Wrap in a minimal `.app` bundle + a Login Item (nicer than the raw LaunchAgent).
- Harden left-to-right ordering across **multiple displays / Spaces** (window
  `bounds` stability).
