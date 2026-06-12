# Design: Shared Session Registry + Per-Session Menu Bar Lights

## Status

- **Status:** Phases 1 (registry writer), 2 (SwiftBar/xbar reader), 3 (click-to-focus), 4 (PID-liveness) all on `main` (Phases 3+4 merged 2026-06-02). Phase 5 (lights ordering) **implemented 2026-06-12** (`sessions order` + native debounced trigger + positional render); see the Phase 5 section.
- **Storage:** SQLite (see [Recommendation](#recommendation)).
- **DB location:** `~/Library/Application Support/TabChroma/sessions.sqlite3` (resolved 2026-05-30).
- **Real-hook validation:** harness `extras/tests/real-hook-check.sh`; (a) durable agent PID + (b) idle-survival confirmed against live Claude sessions 2026-06-02; (c) click-to-focus still needs the interactive run; Codex `session_id` stability still unverified.
- **Next step:** interactive visual confirmation of live left-to-right ordering in the running menu-bar app (CLI `sessions order` + `sessions list` confirmed positional 2026-06-12).

See also: `docs/worm/2026-05-30-session-registry-lights.md` for the append-only discussion log that led to this design.

### Resolved decisions (2026-05-30)

| Question | Decision |
|---|---|
| Registry storage | SQLite, standard-library `sqlite3` |
| DB location | `~/Library/Application Support/TabChroma/` (app-neutral, survives reinstall, shared across Claude + Codex) |
| `done` visibility | Stay green **until the terminal/session exits**; a fallback TTL is the backstop (exact for Claude via `SessionEnd`, TTL-governed for Codex) |
| Explicit session end | **Brief afterglow** (~60s neutral/green) then prune |
| Codex session-end signal | **None available** — the installer registers no `SessionEnd` hook for Codex, so Codex sessions rely on the fallback TTL backstop |
| Menu bar crowding | **Collapse past a threshold** (group like states, full detail in dropdown) |

## Goals

- Track active Claude Code and OpenAI Codex sessions in a shared local registry.
- Render one compact status light per active session.
  - Example: 5 Claude sessions + 2 Codex sessions = 7 menu bar indicators.
- Reuse TabChroma's existing state semantics and colors:
  - `working` → blue
  - `done` → green
  - `attention` → orange
  - `permission` → red
  - `session.start` / reset / idle → neutral or removed, depending on expiry policy
- Keep the first implementation minimal, scriptable, and robust.
- Preserve existing TabChroma terminal behavior.
- Avoid corrupting registry state when multiple hooks fire concurrently.

## Non-goals for the first pass

- No custom animated pixel-pet app yet.
- No iTerm2 geometry/order matching yet.
- No network service or cloud sync.
- No dependency-heavy runtime for the core hook path.
- No blocking/slow UI operations inside hooks.

## Proposed architecture

```text
Claude/Codex hook event
        │
        ▼
  tab-chroma.sh
        │
        ├── existing terminal color/title/badge update
        │
        └── registry update
              │
              ▼
     local session registry
              │
              ▼
  menu bar renderer/plugin
  (SwiftBar/xbar first, native app later)
```

The hook path remains responsible for converting agent lifecycle events into TabChroma states. After resolving the state and session metadata, it records a small session row in a shared registry.

A separate menu bar renderer reads the registry and displays one indicator per active session. This renderer can be a SwiftBar/xbar plugin initially because it is easy to ship and iterate on.

## Registry storage options

### Option A: JSON file with atomic replace + file lock

Example path:

```text
~/.claude/hooks/tab-chroma/sessions.json
```

or, if TabChroma later separates data from Claude-specific paths:

```text
~/Library/Application Support/TabChroma/sessions.json
```

Update algorithm:

1. Acquire an exclusive lock on a lock file, e.g. `sessions.json.lock`.
2. Read `sessions.json` if present.
3. Apply one session update.
4. Prune stale sessions.
5. Write `sessions.json.tmp`.
6. `fsync` if practical.
7. Atomically `rename()` tmp to `sessions.json`.
8. Release lock.

Pros:

- Easy to inspect and debug.
- Easy for SwiftBar/xbar scripts to read.
- No new dependency beyond Python standard library.
- Fine for low write volume.

Cons:

- Correct locking must be implemented carefully.
- Readers can race unless they tolerate transient missing/partial states. Atomic rename avoids partial states, but readers still need error handling.
- Multi-host / network filesystem semantics are not guaranteed.

### Option B: SQLite database

Example path:

```text
~/Library/Application Support/TabChroma/sessions.sqlite3
```

SQLite has built-in file locking and transactional writes. Python's standard library includes `sqlite3`, so this does **not** add a runtime dependency if Python 3 remains a requirement.

Recommended first schema:

```sql
CREATE TABLE IF NOT EXISTS sessions (
  session_key TEXT PRIMARY KEY,
  agent TEXT NOT NULL,
  agent_session_id TEXT NOT NULL,
  state TEXT NOT NULL,
  label TEXT,
  cwd TEXT,
  terminal TEXT,
  theme TEXT,
  color_r INTEGER,
  color_g INTEGER,
  color_b INTEGER,
  started_at INTEGER,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER,
  metadata_json TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);
CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at);
```

Suggested write transaction:

```sql
BEGIN IMMEDIATE;
INSERT INTO sessions (...) VALUES (...)
ON CONFLICT(session_key) DO UPDATE SET
  state = excluded.state,
  label = excluded.label,
  cwd = excluded.cwd,
  terminal = excluded.terminal,
  theme = excluded.theme,
  color_r = excluded.color_r,
  color_g = excluded.color_g,
  color_b = excluded.color_b,
  updated_at = excluded.updated_at,
  expires_at = excluded.expires_at,
  metadata_json = excluded.metadata_json;
DELETE FROM sessions WHERE expires_at IS NOT NULL AND expires_at < unixepoch();
COMMIT;
```

Recommended SQLite pragmas:

```sql
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=250;
PRAGMA synchronous=NORMAL;
```

Pros:

- Built-in cross-process locking.
- Transactions prevent partial updates.
- Readers and writers can coexist well in WAL mode.
- Easier to query, sort, expire, and extend.
- Still uses Python standard library.

Cons:

- Less hand-editable than JSON.
- SwiftBar/xbar shell plugins need either `sqlite3` CLI or a small Python reader.
- Hook code gets more complex than a JSON update.

### Recommendation

Use **SQLite** for the session registry.

Rationale: hooks can fire in parallel across multiple Claude/Codex sessions, and concurrent updates are the primary correctness risk. SQLite's transaction and locking behavior directly solves that risk while staying within the existing Python 3 standard-library requirement for writers. A SwiftBar/xbar reader can use `python3 -c` or a bundled helper script if the `sqlite3` CLI is unavailable.

**Resolved location (2026-05-30):** the DB lives at
`~/Library/Application Support/TabChroma/sessions.sqlite3`, **not** under
`DATA_DIR` (`~/.claude/hooks/tab-chroma/`). Reasons:

- It is shared across both Claude and Codex installs rather than nested under a
  Claude-specific path.
- It survives a plugin reinstall/uninstall — the registry is cross-session
  state, not per-install config, so `cmd_uninstall`'s `rm -rf "$DATA_DIR"`
  should not take it down with it.
- It is the conventional macOS location for app-private data a UI also reads.

Implementation note: the writer must `mkdir -p` the Application Support
directory on first use (it will not exist on a fresh machine), and the
uninstaller should offer to remove it separately from `DATA_DIR` rather than
deleting it implicitly. Define a dedicated `REGISTRY_DIR` /`REGISTRY_DB`
overridable via env (e.g. `TAB_CHROMA_REGISTRY_DB`) so tests can redirect it the
way `TAB_CHROMA_DATA` already redirects `DATA_DIR`.

## Session identity

The registry needs a stable key per live session.

Proposed key:

```text
<agent>:<session_id>
```

Where:

- `agent` is inferred from hook source or config:
  - `claude`
  - `codex`
  - future: `unknown`, `opencode`, etc.
- `session_id` is read from hook JSON.

If a hook event lacks a session id, fallback key:

```text
<agent>:<cwd>:<terminal-window-or-tty>:<pid-if-known>
```

Fallback sessions should have a short expiry to avoid stale indicators.

## Agent detection

First pass detection options:

1. Installer knows which hook file it is writing:
   - Claude settings hook command can include an environment variable:
     - `TAB_CHROMA_AGENT=claude tab-chroma.sh`
   - Codex hooks can include:
     - `TAB_CHROMA_AGENT=codex tab-chroma.sh`
2. If no environment override is present, infer from hook payload shape:
   - Claude has `Notification` and may have Claude-specific fields.
   - Codex lifecycle hooks include event names that overlap with Claude, so payload-shape inference is weaker.

Recommendation: use explicit `TAB_CHROMA_AGENT` in installed hook commands for new installs, while retaining inference/fallback for existing installs.

### Registered events differ between agents

The installer (`tab-chroma.sh`) registers different event sets per agent:

- **Claude** (`tab-chroma.sh:462`): `SessionStart SessionEnd UserPromptSubmit
  PreToolUse PostToolUse Stop Notification PermissionRequest`
- **Codex** (`tab-chroma.sh:463`): `SessionStart UserPromptSubmit PreToolUse
  PostToolUse Stop PermissionRequest`

Two consequences for the registry:

1. **No `SessionEnd` for Codex.** Claude can prune a session deterministically on
   exit; Codex cannot. Codex sessions are therefore removed only by the fallback
   TTL backstop (see TTLs below). This is the resolved answer to the "best Codex
   session end signal" open question: there is none today.
2. **No `Notification` for Codex.** The `attention` state is currently reachable
   only for Claude. Codex sessions express `permission` (via `PermissionRequest`)
   but not the softer `attention` cue. The renderer must not assume every agent
   can produce every state.

## State and color mapping

The registry should store both semantic state and resolved RGB color.

Reasons to store RGB:

- The menu bar renderer can exactly match the active theme.
- Theme changes are reflected at the next event without duplicating theme resolution in the UI.
- Future native/pixel UIs can use the same data.

For reset/done/expired states:

- `working`: active blue light
- `permission`: active red light
- `attention`: active orange light (Claude only — Codex has no `Notification`)
- `done`: green light that stays **until the session exits**, not on a short
  timer (resolved 2026-05-30)
- `session.start`: neutral/reset; creates or refreshes the session row
- session end: mark ended, show a brief afterglow, then prune (resolved
  2026-05-30)

### TTL model (resolved 2026-05-30)

The decision was "`done` stays visible until the terminal exits." For Claude
that exit is observable (`SessionEnd`); for Codex it is not. So `expires_at` is
**not** the primary lifecycle signal — it is a *fallback backstop* that prevents
dead sessions (crash, kill -9, closed terminal with no clean `SessionEnd`) from
lingering forever. Every write sets `expires_at = updated_at + fallback`, and
the deterministic end signal (when it arrives) overrides it.

| State | Light | Removed by | Fallback TTL backstop |
|---|---|---|---|
| `working` / `permission` / `attention` | blue / red / orange | next state change | 2 h since last event |
| `done` | green | `SessionEnd` (Claude); TTL only (Codex) | 12 h since last event |
| `session.start` | neutral | first real activity | 10 min if no activity follows |
| explicit `SessionEnd` | neutral/green afterglow | prune pass | `updated_at + 60 s` |

Afterglow mechanics: on `SessionEnd`, the writer does **not** delete the row.
It sets the state to a terminal/neutral value and `expires_at = now + 60`. The
row is then pruned by the normal `DELETE ... WHERE expires_at < unixepoch()`
step on the next write (or by the renderer / `sessions prune`). This gives a
~60s "just wrapped up" glance without a lingering indicator, and needs no
separate timer.

Codex caveat: because Codex never emits `SessionEnd`, a finished Codex session
shows green until its 12 h `done` backstop elapses (or the user runs
`tab-chroma sessions prune`/`clear`). This is the accepted trade-off of "until
terminal exits" given the available signals. If Codex later exposes an exit
hook, register it and route it to the same afterglow path.

All TTL values above should be config-driven (see Phase 3) rather than
hard-coded, so the backstops can be tuned without code changes.

## Menu bar renderer: first pass

Use SwiftBar or xbar because they render script output directly in the macOS menu bar.

Example compact output:

```text
C● C● C! X● X✓
---
Claude  TabChroma      working     /Users/timh/TabChroma
Claude  deploy-api     permission  /Users/timh/deploy-api
Codex   scratch        done        /tmp/scratch
---
Refresh | refresh=true
Open registry | bash=open param1='open' param2='~/Library/Application Support/TabChroma'
```

Renderer behavior:

- Read all unexpired sessions.
- Sort by `updated_at` initially.
- Render one indicator per session.
- Use agent prefix or icon:
  - `C` for Claude
  - `X` for Codex
- Use color if the renderer supports color markup; otherwise use glyphs:
  - blue working: `●`
  - green done: `✓` or `●`
  - orange attention: `?` or `●`
  - red permission: `!` or `●`

Potential SwiftBar color markup should be validated in implementation. If it is too limited, the first pass can use colored emoji circles:

```text
C🔵 C🟢 C🔴 X🔵 X🟠
```

### Crowding / collapse behavior (resolved 2026-05-30)

Default to one light per session (matches the original "show me 7 indicators"
requirement), but **collapse past a threshold** so the menu bar can't grow
without bound. Proposed rule:

- If `session_count <= COLLAPSE_THRESHOLD` (initial default: 8), render one light
  per session as above.
- If `session_count > COLLAPSE_THRESHOLD`, group by `(agent, state)` and render a
  count badge per group, ordered by agent then state severity:

  ```text
  C🔵×5 C🔴×2 C🟢×3 X🔵×1 X🔴×2
  ```

- The dropdown **always** lists every session individually with full detail
  (agent, label, state, cwd, updated time), collapsed or not — collapsing only
  affects the compact menu bar line, never the detail view.

`COLLAPSE_THRESHOLD` should be config-driven (Phase 3). Threshold counts total
sessions, not per-agent, since the constraint is overall menu bar width.

## Concurrency and race conditions

### What can run concurrently?

- Multiple Claude sessions firing hooks at once.
- Multiple Codex sessions firing hooks at once.
- A single agent turn firing multiple tool hooks rapidly.
- A menu bar reader polling while hooks are writing.

### SQLite behavior

SQLite serializes writes with file locks. With `BEGIN IMMEDIATE`, a writer obtains a reserved lock before modifying data. Other writers wait up to `busy_timeout` or fail. Readers can continue in WAL mode while a writer commits.

### Hook failure policy

Registry updates must be best-effort. If the registry write fails, terminal color/title/badge behavior should still proceed or have already proceeded. A failed registry write should not block or break the agent hook.

Recommended policy:

- Set a short `busy_timeout` (e.g. 250ms).
- If SQLite is locked too long, skip registry update silently or log to debug file when debug mode is enabled.
- Never print registry errors to stdout in hook mode.
- Avoid stderr noise unless `TAB_CHROMA_DEBUG` is enabled.

## Second pass: iTerm2 geometry and left-to-right ordering

Goal: arrange lights in the same left-to-right order as visible iTerm2 tabs.

Potential approaches:

1. **iTerm2 Python API**
   - Query windows, tabs, sessions, and possibly tab/session metadata.
   - Strongest route if API exposes enough geometry/order.
2. **AppleScript / Accessibility APIs**
   - Ask System Events for iTerm2 windows/tabs UI elements.
   - May require Accessibility permission.
   - More brittle across macOS/iTerm2 versions.
3. **Terminal title correlation**
   - TabChroma already writes tab titles.
   - If iTerm2 exposes tab titles in order, match registry session label/title to tab order.
4. **Environment correlation**
   - Capture tty/window/session identifiers from hook environment if available.
   - Later map those identifiers to iTerm2 API objects.

Second-pass design sketch:

```text
registry sessions + iTerm2 tab query
        │
        ▼
match sessions to tabs by tty/title/cwd/session id
        │
        ▼
assign display_order integer
        │
        ▼
menu bar renderer sorts by display_order, then updated_at
```

Open questions:

- What stable identifiers are available in Claude and Codex hook environments?
- Can iTerm2 expose tab order and session tty reliably without user scripting setup?
- Can we avoid Accessibility permissions?
- How should multiple panes/splits within one tab be represented?
- If a session moves between tabs/windows, does the registry key remain correct?


## Phase 3: SwiftBar click-to-focus design

Goal: selecting a session in the SwiftBar/xbar dropdown should raise iTerm2 and
select the window/tab/session that owns that agent session.

### User experience

The menu bar still shows compact lights. The dropdown changes from passive rows
to clickable rows:

```text
🔵  TabChroma — working (3s) | bash=/path/to/tab-chroma param1=sessions param2=focus param3=claude:abc123 terminal=false refresh=true
-- /Users/timh/TabChroma
-- claude:abc123
```

Clicking the top row for a session runs:

```bash
tab-chroma sessions focus <session_key>
```

### Registry identity

The existing registry already stores `terminal`, populated from
`ITERM_SESSION_ID` or `TERM_SESSION_ID`. Phase 3 adds `tty_device` so the
registry stores both:

- `terminal`: agent terminal/session environment id for future matching.
- `tty_device`: resolved tty path such as `/dev/ttys003`, used by the first
  focus implementation.

The schema remains backwards-compatible: installations with an older DB get
`ALTER TABLE sessions ADD COLUMN tty_device TEXT` on the next hook write.

### Focus command

`tab-chroma sessions focus <session_key>` should:

1. Read the registry row by `session_key`.
2. Prefer matching iTerm2 sessions by `tty_device`.
3. Keep `terminal` / `ITERM_SESSION_ID` available as a secondary/future match key.
4. Activate iTerm2.
5. Select the matching window/tab/session.
6. Fall back to `open -a iTerm` / `open -a iTerm2` if no precise match is found.

### Implementation choice

Use AppleScript first because it is built into macOS and does not add a new
runtime dependency. A later implementation can switch to or augment with the
iTerm2 Python API if that provides more reliable IDs and geometry.

### Failure policy

Focusing is best-effort and interactive. It may print a useful error to stderr
when invoked manually, unlike hook mode where output must stay silent. Failure to
focus must never affect hook processing or registry writes.

### Future geometry ordering

The same identity fields (`tty_device`, `terminal`) are prerequisites for the
future left-to-right ordering pass. Once iTerm2 windows/tabs can be matched, a
background/order command can annotate rows with `window_id`, `tab_id`, and
`display_order`.

## Phase 4: PID-liveness session lifecycle (no inactivity expiry)

Stacked on the Phase 3 (`phase3/swiftbar-focus`) branch.

Goal: the lights should be a durable map of **which agent sessions are still
open** — where I was and what I have to go back to — not a recent-activity
feed. A session must stay lit for as long as its process is actually alive, and
disappear only when the process is truly gone. Closing the laptop on Friday and
reopening it Tuesday should leave every still-running session lit.

### Problem with the current model

Every registry write sets `expires_at = now + ttl` (working/permission/attention
2h, `done` 12h, `starting` 10min, `ended` 60s), and `sessions list` / the
SwiftBar reader filter on `expires_at >= now`, with a prune-expired DELETE on
every hook write. A dormant-but-alive session therefore vanishes purely from the
passage of time. It also lets a **stale `tty_device` get reused** by an unrelated
shell, which would make Phase 3 focus the wrong pane — so liveness pruning is a
correctness fix for focus, not just a UX preference.

### Liveness, not a timer

Closing the lid (sleep) does **not** kill processes or renumber PIDs, so a PID
liveness check survives exactly the Fri→Tue scenario. The one hazard is a full
**reboot**, where the OS recycles old PIDs onto unrelated processes; a naive
`kill -0` would then report a dead session as alive and focus garbage.

Guard against recycling by storing the process **start time** alongside the PID
and requiring both to match:

- `session_pid` — PID of the agent process (the nearest tty-owning ancestor the
  hook already walks to in `resolve_terminal_device`; that is the Claude/Codex
  process, not the hook subprocess).
- `pid_start` — that PID's start time, captured as a stable string
  (`ps -o lstart= -p PID`, whitespace-normalised). This is the recycle guard: a
  reused PID will have a different start time.

A row is **alive** iff `session_pid` is set, `kill -0 session_pid` succeeds, and
the current `ps` start time for that PID still equals `pid_start`. Otherwise it
is **dead**.

Schema stays backwards-compatible: older DBs get
`ALTER TABLE sessions ADD COLUMN session_pid INTEGER` and
`ADD COLUMN pid_start TEXT` on the next hook write (same pattern as
`tty_device`).

### Lifecycle rules

- **Live sessions never expire.** When the hook records a row whose PID it can
  resolve, it writes `expires_at = NULL`. The row persists until its process
  dies, regardless of how long it sits idle — including `done` rows, which is
  precisely the "what I have to go back to" indicator.
- **TTL becomes a fallback only.** If the hook cannot resolve a usable PID
  (unexpected environment, no tty ancestor), it keeps the existing TTL backstop
  so such rows still self-clean. PID-bearing rows ignore TTL.
- **Sweep on write replaces prune-on-write.** On each hook write, after the
  upsert, sweep every row: delete rows that are dead by the liveness test, and
  additionally delete PID-less rows whose TTL has expired (preserving today's
  behaviour for the fallback case). Cost is a handful of `kill -0`/`ps` checks
  per write — negligible and off the user-visible path.
- **`SessionEnd` keeps the short afterglow.** A clean exit writes the `ended`
  state with the existing ~60s TTL (it does *not* get the never-expire
  treatment), so the ⚫ afterglow from Phase 2 still fades before the row is
  swept. PID-liveness is the backstop for the unclean cases — crashes and
  `kill -9`, where no SessionEnd fires but the process is gone.
- **`tab-chroma sessions prune`** switches from TTL-pruning to the same liveness
  sweep, so the SwiftBar "Prune" button and any manual prune match the writer.
- **Readers** (`sessions list`, SwiftBar plugin) keep showing rows the sweep has
  not removed. They stay read-only; they do not run the liveness test
  themselves, so a long-idle laptop with no hook events simply keeps showing the
  last-known live set until the next write sweeps it. That is the desired
  behaviour — nothing disappears merely because time passed.

### Caveats

- Cross-host: PIDs are only meaningful on the machine that wrote them. The
  registry is already per-machine (Application Support), so this is moot in
  practice.
- A session that is force-killed while the laptop is asleep will be detected as
  dead on the next hook write from any session, not instantly — acceptable, the
  light just lingers until the next sweep.
- The start-time string format is platform-specific (`ps -o lstart=` on macOS);
  we store and compare it verbatim rather than parsing it, so format drift
  between captures within one boot is not a concern.

### Failure policy

Unchanged from the rest of the registry: the whole block stays inside the
hook's `try/except`, writes nothing to stdout, and any `ps`/`kill` failure
degrades to "treat as the TTL fallback" rather than breaking the hook.

### Bundled nits fixed alongside

- **iTerm session-id secondary match (Phase 3 nit).** Intended to fix it by
  comparing GUID suffixes, but empirically iTerm2's AppleScript `id of s` is a
  *different* GUID from `ITERM_SESSION_ID` (not a prefixed form of the same one),
  so the two can never compare equal. The secondary match was therefore dead
  code that could only mislead. Removed it; `focus` now matches on `tty_device`
  alone, which is the reliable key and also pins the exact pane within a split.
  (`terminal` stays stored for possible future iTerm-variable-based matching.)
- **`sessions list` KEY column** widened so `agent:<uuid>` keys do not wrap.

## Phase 5: lights ordering (left-to-right to match iTerm2 tabs)

> Renumbering note: this is the work the earlier sections call "second pass:
> iTerm2 geometry" and "Phase 4: iTerm2 geometry/order". Since the *real* Phase 4
> became PID-liveness, geometry/ordering is now **Phase 5**. The earlier two
> sections are the original sketch; this section is the current, concrete design
> and supersedes them where they disagree.

Goal: arrange the menu-bar lights in the same left-to-right order as the user's
visible iTerm2 tabs, so the lights read as a spatial map of the windows rather
than a severity/recency sort. Today the reader sorts by state severity then
`updated_at` (see `render_menu_bar`); Phase 5 makes display order *positional*.

### What we already have that makes this tractable

Phase 3 proved the key primitive: iTerm2's AppleScript object model exposes
`tty of s` for every session, and we already store the resolved `tty_device`
(e.g. `/dev/ttys003`) per registry row. So we do **not** need fragile title/cwd
correlation or the iTerm2 Python API — we can enumerate iTerm2 in display order
and join to registry rows on `tty_device`, the same reliable key `focus` uses.
This also means **no Accessibility permission**: it is the same Automation
(Apple Events → iTerm) TCC scope the focus feature already requests.

### Design

Add a `tab-chroma sessions order` command, run **off the hot hook path** (never
inside `process_hook`). It:

1. Walks iTerm2 in display order via AppleScript: `windows` → `tabs of w` →
   `sessions of t`, emitting the `tty of s` for each in iteration order.
2. Assigns an incrementing integer `display_order` as it walks.
3. Writes `display_order` back onto the matching registry row
   (`UPDATE sessions SET display_order=? WHERE tty_device=?`), and clears
   (`NULL`) `display_order` on rows whose tty no longer appears.

Schema: one backward-compatible column, same `ALTER TABLE ... ADD COLUMN` pattern
as `tty_device`/`session_pid`:

```sql
ALTER TABLE sessions ADD COLUMN display_order INTEGER;
```

Renderer change (`render_menu_bar` and the `sessions list` order): when **all**
shown rows have a non-NULL `display_order`, sort by it; otherwise fall back to
the current severity/recency sort. Mixed (some ordered, some not) falls back too,
so a half-populated order never scrambles the line. Collapse behavior is
unchanged — ordering only affects the uncollapsed one-light-per-session line.

### When does `order` run?

Three options, not mutually exclusive; start with the cheapest:

- **A — SwiftBar refresh action / periodic.** The reader (or a dropdown
  "Re-sort to tab order" action) shells out to `tab-chroma sessions order`
  before/while rendering. Simple, but adds an AppleScript round-trip to the UI
  path (~tens of ms) — acceptable off the hook path, and a natural fit for the
  **streamable** plugin (run `order` once per visible change, not per second).
- **B — Debounced from the hook.** The hook could fire `order` in the background
  at most once every N seconds. Risk: it pulls AppleScript latency near the hook;
  must be fully detached and best-effort. Lower priority.
- **C — Manual.** `tab-chroma sessions order` on demand. Always available as the
  primitive the others call.

Recommendation: ship **C** (the command) first, wire **A** into the streamable
plugin, treat **B** as optional.

### Window ordering — the one real decision

Tabs within a window have an unambiguous left-to-right order. *Windows* do not:
AppleScript's `windows` list is roughly front-to-back z-order, which changes as
you click around and is not the same as on-screen left-to-right position. Pinning
true on-screen geometry would require reading window `bounds` (origin x/y) and
sorting by that — doable (bounds are available without Accessibility) and the
preferred refinement. First cut: order by `(window-bounds-x, tab-index,
session-index-within-tab)`. If bounds prove flaky, fall back to AppleScript
window iteration order and document that windows order by focus history.

### Caveats

- **Splits/panes:** a tab with N panes contributes N sessions/lights in pane
  iteration order. That matches "one light per session" and is correct, just
  denser than one-per-tab.
- **tmux / shared tty:** multiple agent sessions multiplexed on one tty collapse
  to a single `tty_device`, so they cannot be ordered apart — same limitation as
  focus. They keep the fallback sort among themselves.
- **Staleness:** `display_order` is a snapshot from the last `order` run; moving a
  tab between runs leaves the light briefly out of position until the next run.
  Acceptable — it self-heals on the next `order`.
- **Non-iTerm / Apple Terminal:** no tab enumeration here, so these rows always
  use the fallback sort. Ordering is an iTerm2-only enhancement.
- **Best-effort, like focus:** any AppleScript failure leaves `display_order`
  untouched and the renderer falls back. It must never break hooks or the reader.

### Open questions for Phase 5

- Is window `bounds`-based left-to-right ordering stable enough across Spaces /
  multiple displays, or should we scope ordering to the frontmost window only?
- Should `display_order` be global across windows, or per-window with a window
  separator glyph in the menu bar (e.g. `🔵🟢 | 🔴`)?
- How much AppleScript latency does a full enumeration add with many
  windows/tabs, and does that argue for caching the walk between renders?

### Implemented (2026-06-12)

What shipped, and where it diverged from the sketch above:

- **`tab-chroma sessions order`** (in `cmd_sessions`): walks iTerm2 read-only via
  `ORDER_SCRIPT`, emitting `win_left⇥win_top⇥seq⇥tty` per session; sorts by
  `(win_left, win_top, seq)` and stamps `display_order = 1..N` onto matching
  `tty_device` rows, NULLing rows whose tty left the layout. Writes **only changed
  rows** (NULL-safe `display_order IS NOT ?`) so a steady layout bumps no mtime.
- **Window ordering** uses on-screen `bounds` (origin x, then y) — the confirmed
  decision, not AppleScript window iteration order.
- **AppleScript gotchas, both resolved:**
  - The `-1700` coercion error is avoided by reading `bounds of w` as integers
    and using the **bulk** `tty of sessions of t` per tab.
  - `tab`/`linefeed` delimiters are built **outside** the `tell application
    "iTerm2"` block — inside it, `tab` resolves to iTerm2's own `tab` class and
    the delimiter would render as the literal word `tab`. Built via
    `character id 9 / 10`.
  - `application "iTerm2" is running` guards the walk so the background poll never
    **launches** iTerm2 (verified launch-safe). Focus remains the only path that
    activates iTerm.
- **Native trigger (option B-ish, app-driven):** `maybeOrder()` runs `sessions
  order` on launch and every ~4 s (8 × 0.5 s ticks), async via `Process`,
  coalesced with `orderInFlight`, skipped when there are no sessions. The existing
  0.5 s mtime watch repaints when `order` changes a row.
- **Render:** `readSessions` selects `display_order` (three-tier query fallback so
  an older DB lacking it still yields tty/pid); `orderedForDisplay` sorts the
  menu-bar line and dropdown by `display_order` only when **every** shown row has
  one, else the prior severity/recency sort. The CLI `sessions list` does the same.
- **Testing:** `unit.sh` stubs the walk via `TAB_CHROMA_ORDER_ENUM` (mirrors the
  `_pane_proc_list` stub) and asserts position-based ranking + stale-tty clearing;
  the native self-test covers `orderedForDisplay` and `display_order` reads.

Deferred open questions: multi-display/Spaces bounds stability and a per-window
separator glyph are untouched — global left-to-right ordering is the v1.

## Implementation plan

### Phase 0: design-only branch

- Add WORM log.
- Add this design doc.
- Push branch for parallel work.

### Phase 1: registry writer — DONE (2026-05-30)

Implemented inline in `tab-chroma.sh` (no separate helper, matching the install
model that ships only `tab-chroma.sh`/themes/completions/VERSION):

- ✅ `REGISTRY_DB` resolves to the Application Support path, overridable via
  `TAB_CHROMA_REGISTRY_DB`; the writer `mkdir -p`s the directory on first use.
  Not `DATA_DIR`.
- ✅ The hook's existing single `python3` block upserts a session row (agent,
  session id, state, cwd, project label, theme, RGB, TTL) at the end, after the
  `.state.json` save. The whole registry section is wrapped in `try/except` and
  writes nothing to stdout, so a registry failure can never break the hook.
- ✅ Registry state + fallback TTL: `working/permission/attention` 2h,
  `done` 12h, `session.start` ("starting") 10min, `SessionEnd` ("ended") 60s
  afterglow. Expired rows are pruned on every write.
- ✅ Agent identity: installer tags hook commands with `TAB_CHROMA_AGENT=claude`
  / `=codex`; reinstall upgrades old untagged entries and de-dupes. Writer
  defaults to `claude` when the env var is absent (old installs).
- ✅ `tab-chroma sessions [list|prune|clear|path]` CLI for inspection.
- ✅ Uninstall leaves the shared registry in place (it is outside `DATA_DIR`) and
  prints how to remove it manually.
- Validated under `/bin/bash 3.2` (the runtime shell): hook simulation,
  afterglow + prune-on-write, TTLs, installer upgrade/idempotency, and the
  `sessions` CLI. (Note: `bash -n` under bash 5 does NOT catch the bash-3.2
  command-substitution apostrophe bug — always syntax-check with `/bin/bash`.)

### Phase 2: SwiftBar/xbar plugin — DONE (2026-05-30)

Implemented `extras/swiftbar/tab-chroma-sessions.1s.py` (+ `extras/swiftbar/README.md`):

- ✅ Reads the SQLite registry **read-only** (`mode=ro` URI), so it never
  creates, writes, or locks the DB and cannot race the hook writers.
- ✅ One light per active (unexpired) session in the menu bar, e.g. `C🔵 C🟢 X🔴`
  (`C`=Claude, `X`=Codex); state→emoji matches the semantic colors
  (working 🔵, done 🟢, attention 🟠, permission 🔴, starting ⚪, ended ⚫).
- ✅ Collapses past `TAB_CHROMA_LIGHTS_COLLAPSE` (default 8) into grouped counts
  (`C🔵×5 X🔴×2`); the dropdown always lists every session.
- ✅ Dropdown rows are colored with the exact theme RGB stored in the registry
  (`color_r/g/b`), with cwd + `agent:session_id` detail submenus.
- ✅ Actions: Refresh, Prune expired, Clear all (via auto-detected `tab-chroma`
  binary), Open registry folder.
- ✅ Graceful states: idle shows a dim `○`; an unreadable DB shows a `⚠️` line;
  dynamic values are sanitized so a `|`/newline in a path or label can't corrupt
  a menu row.
- Validated against a populated temp registry: idle, multi-session, collapse,
  RGB coloring, and `|`-sanitization.

Open follow-up: still want to confirm Codex `session_id` stability against real
payloads, and Phase 4 (iTerm2 geometry ordering) remains future work.

### Phase 3: polish

- Configurable TTLs.
- Better labels.
- Agent icons.
- Optional debug command to dump registry state.
- Optional `tab-chroma sessions` CLI subcommands:
  - `tab-chroma sessions list`
  - `tab-chroma sessions prune`
  - `tab-chroma sessions clear`

### Phase 4: iTerm2 geometry/order

- Prototype iTerm2 tab enumeration.
- Add a separate order updater, not in the hot hook path.
- Store `display_order`, `window_id`, `tab_id`, and confidence/match reason in registry.
- Sort renderer by `display_order` when available.

## Open questions

Resolved 2026-05-30 (see [Resolved decisions](#resolved-decisions-2026-05-30)):
DB location, `done` visibility, session-end behavior, Codex end signal, menu
bar crowding/collapse, and uninstall semantics.

**Uninstall semantics — resolved (implemented in Phase 1).** Because the
registry lives in Application Support, `cmd_uninstall`'s `rm -rf "$DATA_DIR"`
does not touch it. Uninstall now **leaves the shared registry in place** (it may
still be used by a sibling agent install) and prints the path plus a manual
`rm -f` command, rather than deleting or prompting. See `tab-chroma.sh`
`cmd_uninstall`.

Still open:

- **Codex identity stability.** Does the Codex `session_id` stay constant across
  a session's hook events, or does it need the fallback composite key? Verify in
  Phase 2 against real Codex payloads before committing to the key shape.
- **iTerm2 geometry (Phase 4).** The second-pass open questions below remain —
  what stable identifiers exist in Claude/Codex hook environments, whether
  iTerm2 can expose tab order/tty without Accessibility permissions, and how
  panes/splits and tab moves map to registry keys.

## Current recommendation

Proceed with SQLite for the shared registry and a SwiftBar/xbar reader for the first UI. This gives robust concurrent updates, keeps TabChroma scriptable, and supports one indicator per active session without prematurely building a custom macOS app.

With the 2026-05-30 decisions resolved (DB in Application Support, `done` lives
until exit with a TTL backstop, ~60s afterglow on `SessionEnd`, collapse past 8
sessions, and explicit `TAB_CHROMA_AGENT` tagging), Phase 1 (the registry
writer) is unblocked and is the next concrete step. The one item to validate
during Phase 1 itself is Codex `session_id` stability against real payloads.
