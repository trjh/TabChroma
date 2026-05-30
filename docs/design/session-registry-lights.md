# Design: Shared Session Registry + Per-Session Menu Bar Lights

## Status

Draft design, created 2026-05-30 on branch `design/session-registry-lights`.

See also: `docs/worm/2026-05-30-session-registry-lights.md` for the append-only discussion log that led to this design.

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

## State and color mapping

The registry should store both semantic state and resolved RGB color.

Reasons to store RGB:

- The menu bar renderer can exactly match the active theme.
- Theme changes are reflected at the next event without duplicating theme resolution in the UI.
- Future native/pixel UIs can use the same data.

For reset/done/expired states:

- `working`: active blue light
- `permission`: active red light
- `attention`: active orange light
- `done`: green light, then expire after a configurable TTL
- `session.start`: neutral/reset; can create or update session with short TTL
- session end/reset event: either mark ended and expire quickly, or delete immediately

Proposed initial TTLs:

- `working`, `permission`, `attention`: 2 hours unless refreshed
- `done`: 30 minutes
- `session.start`: 10 minutes unless followed by activity
- explicit session end: delete immediately or expire after 60 seconds

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

## Implementation plan

### Phase 0: design-only branch

- Add WORM log.
- Add this design doc.
- Push branch for parallel work.

### Phase 1: registry writer

- Add a small Python helper, e.g. `scripts/tab_chroma_registry.py` or inline function in `tab-chroma.sh`.
- Create/open SQLite DB in data dir.
- On each resolved hook event, upsert session row with agent, session id, state, cwd, project label, theme, RGB, and TTL.
- Prune expired sessions during writes.
- Keep registry update best-effort and silent in hook mode.

### Phase 2: SwiftBar/xbar plugin

- Add `extras/swiftbar/tab-chroma-sessions.1s.py` or `.sh`.
- Read SQLite registry.
- Render compact one-light-per-session output.
- Include dropdown rows with details.
- Document install steps.

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

- Should the database live under the current `DATA_DIR` or a more app-neutral macOS Application Support path?
- Should `done` sessions remain visible for 30 minutes, until terminal exits, or until the next session starts?
- Should explicit session end delete immediately or leave a brief neutral/green afterglow?
- What is the best Codex session end signal, if any, besides `Stop`?
- How much detail should the menu bar show before it becomes too wide?
- Should the renderer collapse many sessions after a threshold, e.g. `C🔵×5 X🔴×2`, or always show one element per session as requested?

## Current recommendation

Proceed with SQLite for the shared registry and a SwiftBar/xbar reader for the first UI. This gives robust concurrent updates, keeps TabChroma scriptable, and supports one indicator per active session without prematurely building a custom macOS app.
