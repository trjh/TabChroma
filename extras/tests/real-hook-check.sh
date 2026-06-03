#!/usr/bin/env bash
# real-hook-check.sh — validate the TabChroma session registry inside a REAL
# Claude Code / Codex hook environment.
#
# Everything before this script existed was validated only with *simulated* hook
# writes under bash 3.2 (migration, live/dead/recycled sweeps, afterglow, focus,
# SwiftBar render). This harness closes the three gaps that can only be confirmed
# against a process tree produced by an actual agent:
#
#   (a) the resolved session_pid is the durable AGENT process (Claude/Codex),
#       not a transient per-invocation wrapper (bash -c / python3 / the hook);
#   (b) a still-running session survives an arbitrarily long idle gap (the
#       Phase 4 "lights are a durable map, not an activity feed" guarantee);
#   (c) click-to-focus raises the right iTerm2 pane.
#
# It is SAFE: every check against the real registry is read-only. The only
# writes happen to a throwaway temp DB (via TAB_CHROMA_REGISTRY_DB) for the
# deterministic idle-survival / liveness-sweep test. It never prunes, clears, or
# otherwise mutates ~/Library/Application Support/TabChroma/sessions.sqlite3.
#
# Usage:
#   extras/tests/real-hook-check.sh            # run all non-interactive checks
#   extras/tests/real-hook-check.sh focus [KEY] # interactive: raise a session's pane
#   extras/tests/real-hook-check.sh --help
#
# How to use it for real (the AFK-deferred validation):
#   1. In an iTerm2 tab, start Claude Code (or Codex) and let it do one turn so a
#      hook fires and writes a row.
#   2. In the SAME tab (or any tab), run this script. The "real registry" phase
#      reports on every live session; (a) and (b) are asserted automatically.
#   3. For (c): note your session's KEY from the printed table, then run
#      `extras/tests/real-hook-check.sh focus <KEY>` and confirm iTerm jumps to it.

set -u

# ─── Locations ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_SH="$REPO_ROOT/tab-chroma.sh"
INSTALLED_SH="${TAB_CHROMA_INSTALLED:-$HOME/.claude/hooks/tab-chroma/tab-chroma.sh}"
REGISTRY_DB="${TAB_CHROMA_REGISTRY_DB:-$HOME/Library/Application Support/TabChroma/sessions.sqlite3}"

# Prefer the installed binary for CLI exercises (that is what really runs in
# hooks); fall back to the repo copy.
TC_BIN="$INSTALLED_SH"
[ -x "$TC_BIN" ] || TC_BIN="$REPO_SH"

# ─── Output helpers ─────────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0
if [ -t 1 ]; then
  C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GRN=; C_RED=; C_YEL=; C_DIM=; C_OFF=
fi
pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$C_GRN" "$C_OFF" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$1"; }
warn() { WARN=$((WARN+1)); printf '  %sWARN%s %s\n' "$C_YEL" "$C_OFF" "$1"; }
info() { printf '  %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
hdr()  { printf '\n%s──%s %s\n' "$C_DIM" "$C_OFF" "$1"; }

usage() {
  cat <<'USAGE'
real-hook-check.sh — validate the TabChroma session registry inside a REAL
Claude Code / Codex hook environment.

Closes the three gaps that can only be confirmed against a real agent process tree:
  (a) session_pid is the durable AGENT process, not a transient wrapper;
  (b) a still-running session survives an arbitrarily long idle gap;
  (c) click-to-focus raises the right iTerm2 pane.

Safe: every check against the real registry is read-only. The only writes go to
a throwaway temp DB (via TAB_CHROMA_REGISTRY_DB) for the deterministic sweep test.

Usage:
  real-hook-check.sh             Run all non-interactive checks (A install-sync,
                                 B live registry, D deterministic sweep).
  real-hook-check.sh focus [KEY] Interactive: raise a session's iTerm2 pane.
                                 With no KEY, auto-selects the only live session.
  real-hook-check.sh --help      This help.

Exit status: nonzero if any check FAILs (warnings do not fail the run).

How to run the deferred live validation:
  1. Start Claude Code / Codex in an iTerm2 tab; let one turn fire a hook.
  2. Run with no args; (a) and (b) are asserted automatically.
  3. Note your session's KEY, then: real-hook-check.sh focus '<KEY>'
USAGE
  exit 0
}

# ─── Phase A: install sync ──────────────────────────────────────────────────
check_install_sync() {
  hdr "A. Install sync (repo copy vs live hook copy)"
  if [ ! -f "$REPO_SH" ]; then
    fail "repo tab-chroma.sh not found at $REPO_SH"; return
  fi
  if [ ! -f "$INSTALLED_SH" ]; then
    warn "no installed copy at $INSTALLED_SH — run 'bash install.sh' before live testing"
    return
  fi
  if cmp -s "$REPO_SH" "$INSTALLED_SH"; then
    pass "installed hook is identical to the repo copy"
  else
    fail "installed hook DIFFERS from the repo copy — run 'bash install.sh' to sync"
    info "diff: diff '$REPO_SH' '$INSTALLED_SH'"
  fi
}

# ─── Phase B+C: real registry, PID anchoring, idle-survival mechanism ────────
# The heavy lifting is one python3 pass over the live registry (read-only).
check_real_registry() {
  hdr "B. Live registry — PID anchoring (a) + idle-survival mechanism (b)"
  if [ ! -f "$REGISTRY_DB" ]; then
    warn "no registry yet at $REGISTRY_DB — start an agent and let one hook fire first"
    return
  fi
  DB="$REGISTRY_DB" python3 - <<'PYEOF'
import os, sqlite3, subprocess, sys, time
db = os.environ["DB"]
now = int(time.time())
GRN="\033[32m"; RED="\033[31m"; YEL="\033[33m"; DIM="\033[2m"; OFF="\033[0m"
if not sys.stdout.isatty():
    GRN=RED=YEL=DIM=OFF=""
# Tally so the phase can propagate a real failure into the script exit status
# (a FAIL line must not coexist with a 0-failure summary / exit 0).
TALLY = {"pass": 0, "fail": 0, "warn": 0}
def P(s): TALLY["pass"] += 1; print(f"  {GRN}PASS{OFF} {s}")
def F(s): TALLY["fail"] += 1; print(f"  {RED}FAIL{OFF} {s}")
def W(s): TALLY["warn"] += 1; print(f"  {YEL}WARN{OFF} {s}")
def I(s): print(f"  {DIM}{s}{OFF}")

con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
con.row_factory = sqlite3.Row
cols = {r[1] for r in con.execute("PRAGMA table_info(sessions)")}
need = {"session_pid", "pid_start", "tty_device", "expires_at"}
missing = need - cols
if missing:
    W(f"schema missing columns {sorted(missing)} — DB predates Phase 3/4; "
      "it migrates on the next live hook write")

rows = con.execute("SELECT * FROM sessions").fetchall()
live = [r for r in rows if r["expires_at"] is None or (r["expires_at"] or 0) >= now]
I(f"{len(rows)} row(s) total, {len(live)} live")
if not live:
    W("no live sessions — run a Claude/Codex turn so a hook writes a row, then re-run")
    sys.exit(0)

def ps_field(pid, fmt):
    try:
        return " ".join(subprocess.run(
            ["/bin/ps", "-o", fmt, "-p", str(pid)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=2).stdout.split())
    except Exception:
        return ""

def norm_start(s):
    # Locale/order-tolerant key for a `ps -o lstart=` string. The format depends
    # on the caller's LC_TIME — e.g. "Wed 3 Jun 09:56:19 2026" (en_GB-ish) vs
    # "Wed Jun 3 09:56:19 2026" (C/US) — so a raw string compare false-mismatches
    # when the agent that WROTE the row and this shell differ in locale. Dropping
    # the weekday and comparing the remaining tokens as a sorted set keys on the
    # actual start instant, not its rendering.
    toks = s.split()
    return tuple(sorted(toks[1:])) if len(toks) > 1 else tuple(sorted(toks))

# Heuristic: the durable anchor should be the agent, not a per-invocation
# wrapper. These comms would mean resolve_terminal_target latched the wrong pid.
WRAPPER_COMMS = ("python", "python3", "tab-chroma", "tab-chroma.sh", "osascript")
AGENT_COMMS   = ("node", "claude", "codex")

print()
for r in live:
    key   = r["session_key"]
    state = r["state"]
    pid   = r["session_pid"] if "session_pid" in cols else None
    start = (r["pid_start"] if "pid_start" in cols else "") or ""
    tty   = (r["tty_device"] if "tty_device" in cols else "") or ""
    exp   = r["expires_at"]
    age   = now - (r["updated_at"] or now)
    print(f"  {DIM}• {key}  state={state} age={age}s{OFF}")

    # (a) durable agent PID — not a transient wrapper.
    if not pid:
        W(f"    no session_pid recorded — PID-less fallback row (relies on TTL); "
          "expected only in odd environments")
    else:
        try:
            os.kill(int(pid), 0); alive = True
        except ProcessLookupError:
            alive = False
        except PermissionError:
            alive = True   # process exists but isn't ours (e.g. root) → still alive
        except Exception:
            alive = False
        comm = ps_field(pid, "comm=")
        base = os.path.basename(comm) if comm else ""
        lstart = ps_field(pid, "lstart=")
        if alive:
            # If the pid is still alive now — long after the hook that wrote it
            # exited — it cannot have been a transient per-invocation wrapper.
            P(f"    session_pid {pid} ({base or '?'}) still alive → durable anchor (a)")
        else:
            F(f"    session_pid {pid} is DEAD but row is still live → stale/wrong anchor (a)")
        if base:
            if any(w in base for w in WRAPPER_COMMS):
                F(f"    anchor comm '{base}' looks like a WRAPPER, not the agent (a)")
            elif any(a in base for a in AGENT_COMMS):
                P(f"    anchor comm '{base}' looks like the agent process (a)")
            else:
                W(f"    anchor comm '{base}' — verify this is the durable agent/login "
                  "shell, not a wrapper (a)")
        # recycle guard: stored pid_start must key to the same start instant as
        # the live PID. Compared locale-tolerantly (see norm_start) — a reused
        # PID would show a genuinely different instant, not just a reformatting.
        if start and lstart:
            if norm_start(start) == norm_start(lstart):
                P(f"    pid_start keys to the same start instant → recycle guard intact (a)")
                if start != lstart:
                    W(f"    stored '{start}' vs this shell's '{lstart}' differ in FORMAT "
                      "only (locale). NB: the SHIPPED guard in tab-chroma.sh does a RAW "
                      "string compare, so a `sessions prune` run under a different LC_TIME "
                      "than the agent would wrongly prune this live row. Recommended "
                      "follow-up: make the shipped compare locale-tolerant (force LC_ALL=C "
                      "or the same token-set compare).")
            else:
                F(f"    pid_start INSTANT mismatch (stored='{start}' now='{lstart}') → "
                  "reused PID or capture bug (a)")
        elif not start:
            W("    no pid_start stored — recycle guard degraded to bare kill(0)")

    # (b) idle-survival mechanism: a live PID-anchored, non-ended row must carry
    # expires_at IS NULL, which is *exactly* what makes idle time unable to drop
    # it (readers filter `expires_at IS NULL OR >= now`).
    if pid and state != "ended":
        if exp is None:
            P(f"    expires_at IS NULL → cannot expire on idle time (b)")
        else:
            F(f"    expires_at={exp} on a live PID row → would vanish after idle (b regression)")
    elif state == "ended":
        I("    state=ended → keeps short afterglow TTL by design (not idle-survival)")

con.close()
print(f"  {DIM}[phase B tally: {TALLY['pass']} pass, {TALLY['fail']} fail, {TALLY['warn']} warn]{OFF}")
# Real assertion failures must surface as a nonzero exit so the script can't
# print FAIL lines and still report success. Warnings (incl. the locale note)
# do not fail the run.
sys.exit(2 if TALLY["fail"] else 0)
PYEOF
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    FAIL=$((FAIL+1))
    info "phase B reported failures (see FAIL lines above) → counted in summary"
  fi
}

# ─── Phase D: deterministic liveness-sweep / idle-survival test ──────────────
# Builds a throwaway DB with (1) an ancient-but-live row and (2) a dead-pid row,
# then runs the REAL `tab-chroma sessions prune` against it and asserts the live
# row survives a 7-day idle gap while the dead one is swept. This exercises the
# shipped Phase 4 code path deterministically, with no waiting and no touching
# the real registry.
check_sweep_deterministic() {
  hdr "D. Deterministic liveness sweep + idle survival (throwaway DB)"
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tc-realhook.XXXXXX")" || { fail "mktemp failed"; return; }
  local tdb="$tmp/sessions.sqlite3"

  # Seed the temp DB with the same schema the writer creates.
  SEED_DB="$tdb" SEED_PID="$$" python3 - <<'PYEOF'
import os, sqlite3, subprocess, time
db = os.environ["SEED_DB"]; pid = int(os.environ["SEED_PID"]); now = int(time.time())
def lstart(p):
    return " ".join(subprocess.run(["/bin/ps","-o","lstart=","-p",str(p)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.split())
con = sqlite3.connect(db)
con.execute("""CREATE TABLE sessions (
  session_key TEXT PRIMARY KEY, agent TEXT NOT NULL, agent_session_id TEXT,
  state TEXT NOT NULL, label TEXT, cwd TEXT, terminal TEXT, theme TEXT,
  color_r INTEGER, color_g INTEGER, color_b INTEGER, started_at INTEGER,
  updated_at INTEGER NOT NULL, expires_at INTEGER, session_pid INTEGER,
  pid_start TEXT, tty_device TEXT, metadata_json TEXT)""")
week = 7*24*3600
# (1) live + PID-anchored + NULL expiry + updated a week ago → must survive.
con.execute("INSERT INTO sessions(session_key,agent,state,label,updated_at,"
            "expires_at,session_pid,pid_start) VALUES(?,?,?,?,?,?,?,?)",
            ("test:alive", "claude", "done", "ancient-but-alive",
             now-week, None, pid, lstart(pid)))
# (2) dead pid + NULL expiry → must be swept by the liveness check.
con.execute("INSERT INTO sessions(session_key,agent,state,label,updated_at,"
            "expires_at,session_pid,pid_start) VALUES(?,?,?,?,?,?,?,?)",
            ("test:dead", "claude", "working", "dead-process",
             now, None, 999999, "bogus start time"))
con.commit(); con.close()
PYEOF
  if [ ! -f "$tdb" ]; then fail "could not seed temp DB"; rm -rf "$tmp"; return; fi

  # Run the SHIPPED prune against the temp DB.
  local out
  out="$(TAB_CHROMA_REGISTRY_DB="$tdb" "$TC_BIN" sessions prune 2>&1)"
  info "prune said: $out"

  # Assert outcome by reading the temp DB directly.
  TDB="$tdb" python3 - <<'PYEOF'
import os, sqlite3, sys
db=os.environ["TDB"]; con=sqlite3.connect(db); con.row_factory=sqlite3.Row
keys={r["session_key"] for r in con.execute("SELECT session_key FROM sessions")}
con.close()
GRN="\033[32m"; RED="\033[31m"; OFF="\033[0m"
if not sys.stdout.isatty(): GRN=RED=OFF=""
ok=True
if "test:alive" in keys:
    print(f"  {GRN}PASS{OFF} week-idle live session survived the sweep (b)")
else:
    print(f"  {RED}FAIL{OFF} week-idle live session was wrongly pruned (b)"); ok=False
if "test:dead" not in keys:
    print(f"  {GRN}PASS{OFF} dead-process session was swept (Phase 4 liveness)")
else:
    print(f"  {RED}FAIL{OFF} dead-process session lingered (Phase 4 regression)"); ok=False
sys.exit(0 if ok else 1)
PYEOF
  if [ $? -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  rm -rf "$tmp"
}

# ─── focus (interactive, c) ─────────────────────────────────────────────────
do_focus() {
  local key="${1:-}"
  hdr "C. Click-to-focus (interactive)"
  if [ ! -f "$REGISTRY_DB" ]; then fail "no registry to focus against"; return 1; fi
  if [ -z "$key" ]; then
    # Auto-pick if exactly one live row, else show the table and ask for a key.
    key="$(DB="$REGISTRY_DB" python3 - <<'PYEOF'
import os, sqlite3, time
db=os.environ["DB"]; now=int(time.time())
con=sqlite3.connect(f"file:{db}?mode=ro", uri=True); con.row_factory=sqlite3.Row
live=[r for r in con.execute("SELECT * FROM sessions") if r["expires_at"] is None or (r["expires_at"] or 0)>=now]
con.close()
print(live[0]["session_key"] if len(live)==1 else "")
PYEOF
)"
    if [ -z "$key" ]; then
      info "More than one (or zero) live session; pick a KEY from:"
      "$TC_BIN" sessions list
      info "Then run: $0 focus '<KEY>'"
      return 1
    fi
    info "auto-selected the only live session: $key"
  fi
  info "running: $TC_BIN sessions focus '$key'"
  "$TC_BIN" sessions focus "$key"
  local rc=$?
  if [ $rc -eq 0 ]; then
    pass "focus command returned success — confirm iTerm jumped to the right pane (c)"
  else
    warn "focus returned $rc — check the on-screen/notification message (TCC? closed tab?) (c)"
  fi
  return $rc
}

# ─── main ───────────────────────────────────────────────────────────────────
case "${1:-}" in
  -h|--help) usage ;;
  focus)     shift; do_focus "${1:-}"; exit $? ;;
esac

printf '%sTabChroma real-hook check%s\n' "$C_DIM" "$C_OFF"
info "registry: $REGISTRY_DB"
info "binary:   $TC_BIN"
[ "${TERM_PROGRAM:-}" = "iTerm.app" ] || warn "TERM_PROGRAM != iTerm.app — run this inside the iTerm2 session you want to validate"

check_install_sync
check_real_registry
check_sweep_deterministic

hdr "Summary"
printf '  %s%d passed%s, %s%d failed%s, %s%d warnings%s\n' \
  "$C_GRN" "$PASS" "$C_OFF" "$C_RED" "$FAIL" "$C_OFF" "$C_YEL" "$WARN" "$C_OFF"
info "For the focus check (c): $0 focus '<KEY-from-table-above>'"
[ "$FAIL" -eq 0 ]
