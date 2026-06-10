#!/usr/bin/env bash
# Dependency-free unit checks for tab-chroma.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TC_BIN="$REPO_ROOT/tab-chroma.sh"

PASS=0
FAIL=0
SKIP=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() {
  PASS=$((PASS + 1))
  printf 'PASS %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1"
}

skip() {
  SKIP=$((SKIP + 1))
  printf 'SKIP %s\n' "$1"
}

fresh_data() {
  local dir
  dir="$(mktemp -d "$TMP_ROOT/case.XXXXXX")"
  mkdir -p "$dir/home"
  printf '%s\n' "$dir"
}

run_tc() {
  local data="$1"
  shift
  TAB_CHROMA_DATA="$data" \
  TAB_CHROMA_SHARE="$REPO_ROOT" \
  TAB_CHROMA_REGISTRY_DB="$data/sessions.sqlite3" \
  TERM_PROGRAM=iTerm.app \
  HOME="$data/home" \
    bash "$TC_BIN" "$@"
}

run_hook() {
  local data="$1"
  local input="$2"
  TAB_CHROMA_DATA="$data" \
  TAB_CHROMA_SHARE="$REPO_ROOT" \
  TAB_CHROMA_REGISTRY_DB="$data/sessions.sqlite3" \
  TAB_CHROMA_AGENT="${TAB_CHROMA_AGENT:-claude}" \
  TERM_PROGRAM=iTerm.app \
  HOME="$data/home" \
    bash "$TC_BIN" <<<"$input"
}

check() {
  local name="$1"
  shift
  "$@"
  local rc=$?
  case "$rc" in
    0) pass "$name";;
    2) skip "$name";;
    *) fail "$name";;
  esac
}

json_expr() {
  local data="$1"
  local file="$2"
  local expr="$3"
  DATA="$data" FILE="$file" EXPR="$expr" python3 - <<'PYEOF'
import json, os
path = os.path.join(os.environ["DATA"], os.environ["FILE"])
with open(path) as f:
    d = json.load(f)
print(eval(os.environ["EXPR"], {}, {"d": d}))
PYEOF
}

sqlite_expr() {
  local data="$1"
  local expr="$2"
  DATA="$data" EXPR="$expr" python3 - <<'PYEOF'
import os, sqlite3
con = sqlite3.connect(os.path.join(os.environ["DATA"], "sessions.sqlite3"))
con.row_factory = sqlite3.Row
print(eval(os.environ["EXPR"], {}, {"con": con}))
con.close()
PYEOF
}

case_status_creates_config() {
  local data out active
  data="$(fresh_data)"
  out="$(run_tc "$data" status)"
  active="$(json_expr "$data" config.json 'd["active_theme"]')"
  [[ "$out" == *"tab-chroma v"* && "$active" == "default" ]]
}

case_theme_use_persists() {
  local data out active
  data="$(fresh_data)"
  out="$(run_tc "$data" theme use dracula)"
  active="$(json_expr "$data" config.json 'd["active_theme"]')"
  [[ "$out" == "active theme set to: dracula" && "$active" == "dracula" ]]
}

case_feature_toggle_updates_config() {
  local data out enabled
  data="$(fresh_data)"
  out="$(run_tc "$data" badge off)"
  enabled="$(json_expr "$data" config.json 'd["features"]["badge"]')"
  [[ "$out" == "badge: off" && "$enabled" == "False" ]]
}

case_pause_resume_toggle_files() {
  local data
  data="$(fresh_data)"
  run_tc "$data" pause >/dev/null || return 1
  [ -f "$data/.paused" ] || return 1
  run_tc "$data" resume >/dev/null || return 1
  [ ! -f "$data/.paused" ]
}

case_invalid_test_state_fails() {
  local data err
  data="$(fresh_data)"
  err="$(run_tc "$data" test not-a-state 2>&1)"
  [[ $? -ne 0 && "$err" == *"unknown state: not-a-state"* ]]
}

case_unknown_theme_fails() {
  local data err
  data="$(fresh_data)"
  err="$(run_tc "$data" theme use missing-theme 2>&1)"
  [[ $? -ne 0 && "$err" == *"theme not found: missing-theme"* ]]
}

case_hook_user_prompt_writes_working_state() {
  local data state
  data="$(fresh_data)"
  run_hook "$data" '{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/demo","session_id":"s1"}' >/dev/null || return 1
  state="$(json_expr "$data" .state.json 'd["last_state"]')"
  [[ "$state" == "working" ]]
}

case_hook_stop_writes_done_state() {
  local data state
  data="$(fresh_data)"
  run_hook "$data" '{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/demo","session_id":"s1"}' >/dev/null || return 1
  run_hook "$data" '{"hook_event_name":"Stop","cwd":"/tmp/demo","session_id":"s1"}' >/dev/null || return 1
  state="$(json_expr "$data" .state.json 'd["last_state"]')"
  [[ "$state" == "done" ]]
}

case_hook_duplicate_state_debounces() {
  local data before after
  data="$(fresh_data)"
  run_hook "$data" '{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/demo","session_id":"s1"}' >/dev/null || return 1
  before="$(json_expr "$data" .state.json 'd["last_state_time"]')"
  run_hook "$data" '{"hook_event_name":"PreToolUse","cwd":"/tmp/demo","session_id":"s1"}' >/dev/null || return 1
  after="$(json_expr "$data" .state.json 'd["last_state_time"]')"
  [[ "$before" == "$after" ]]
}

case_permission_bypasses_debounce() {
  local data before after
  data="$(fresh_data)"
  run_hook "$data" '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo","session_id":"s1"}' >/dev/null || return 1
  before="$(json_expr "$data" .state.json 'd["last_state_time"]')"
  run_hook "$data" '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo","session_id":"s1"}' >/dev/null || return 1
  after="$(json_expr "$data" .state.json 'd["last_state_time"]')"
  python3 - "$before" "$after" <<'PYEOF'
import sys
sys.exit(0 if float(sys.argv[2]) >= float(sys.argv[1]) else 1)
PYEOF
}

case_hook_disabled_config_skips_state() {
  local data
  data="$(fresh_data)"
  DATA="$data" python3 - <<'PYEOF'
import json, os
cfg = {
    "active_theme": "default",
    "enabled": False,
    "features": {"tab_color": True, "badge": True, "title": True},
    "states": {},
    "debounce_seconds": 2,
}
with open(os.path.join(os.environ["DATA"], "config.json"), "w") as f:
    json.dump(cfg, f)
PYEOF
  run_hook "$data" '{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/demo","session_id":"s1"}' >/dev/null || return 1
  [ ! -f "$data/.state.json" ]
}

case_registry_records_and_lists_session() {
  local data out db_state db_theme
  data="$(fresh_data)"
  run_hook "$data" '{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/demo","session_id":"s1"}' >/dev/null || return 1
  db_state="$(sqlite_expr "$data" 'con.execute("select state from sessions where session_key = ?", ("claude:s1",)).fetchone()["state"]')"
  db_theme="$(sqlite_expr "$data" 'con.execute("select theme from sessions where session_key = ?", ("claude:s1",)).fetchone()["theme"]')"
  out="$(run_tc "$data" sessions list)"
  [[ "$db_state" == "working" && "$db_theme" == "default" && "$out" == *"claude:s1"* && "$out" == *"working"* ]]
}

case_native_app_self_test() {
  local data bin cache
  if ! command -v swiftc >/dev/null 2>&1; then
    return 2
  fi
  data="$(fresh_data)"
  bin="$data/tabchroma-lights"
  cache="$data/swift-module-cache"
  mkdir -p "$cache"
  swiftc -swift-version 5 -O -module-cache-path "$cache" \
    "$REPO_ROOT/native/main.swift" -o "$bin" -framework AppKit || return 1
  TAB_CHROMA_REGISTRY_DB="$data/native-sessions.sqlite3" \
  TAB_CHROMA_LIGHTS_COLLAPSE=2 \
    "$bin" --self-test
}

# Load resolve_via_pane_env from the source script (it is a pure function; the
# rest of tab-chroma.sh self-dispatches on args/stdin, so we extract just this).
load_pane_env_fn() {
  eval "$(awk '/^resolve_via_pane_env\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$TC_BIN")"
}

case_pane_env_bogus_sid_no_match() {
  # Deterministic everywhere: a session id no process can have must not match,
  # and must leave the /dev/tty fallback (and empty pid) untouched.
  load_pane_env_fn || return 1
  TTY_DEVICE="/dev/tty"; TTY_PID=""
  resolve_via_pane_env "w9t9p9:NO-SUCH-SESSION-000000000000" "codex"
  [ "$?" -eq 1 ] && [ "$TTY_DEVICE" = "/dev/tty" ] && [ -z "$TTY_PID" ]
}

case_pane_env_empty_sid_returns_skip() {
  load_pane_env_fn || return 1
  TTY_DEVICE="/dev/tty"; TTY_PID=""
  resolve_via_pane_env "" "codex"
  [ "$?" -eq 1 ] && [ "$TTY_DEVICE" = "/dev/tty" ]
}

case_pane_env_resolves_real_pane() {
  # Real check: from inside an iTerm/Terminal pane, the running test process
  # carries ITERM_SESSION_ID/TERM_SESSION_ID and a real tty, so resolving that
  # session id should recover this very tty. Skipped where there is no pane
  # (CI, piped run) — that environment is covered by real-hook-check.sh.
  local sid tty_now
  sid="${ITERM_SESSION_ID:-${TERM_SESSION_ID:-}}"
  tty_now="$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')"
  [ -n "$sid" ] && [ -n "$tty_now" ] && [ "$tty_now" != "??" ] && [ -w "/dev/$tty_now" ] || return 2
  load_pane_env_fn || return 1
  TTY_DEVICE="/dev/tty"; TTY_PID=""
  resolve_via_pane_env "$sid" "" || return 1
  [ "$TTY_DEVICE" = "/dev/$tty_now" ] && [ -n "$TTY_PID" ]
}

check "status creates default config" case_status_creates_config
check "theme use persists active theme" case_theme_use_persists
check "feature toggle updates config" case_feature_toggle_updates_config
check "pause/resume manages paused file" case_pause_resume_toggle_files
check "invalid test state fails" case_invalid_test_state_fails
check "unknown theme fails" case_unknown_theme_fails
check "hook maps UserPromptSubmit to working" case_hook_user_prompt_writes_working_state
check "hook maps Stop to done" case_hook_stop_writes_done_state
check "hook debounces duplicate working state" case_hook_duplicate_state_debounces
check "permission bypasses debounce" case_permission_bypasses_debounce
check "disabled config skips hook state" case_hook_disabled_config_skips_state
check "registry records and lists session" case_registry_records_and_lists_session
check "pane-env fallback ignores unknown session id" case_pane_env_bogus_sid_no_match
check "pane-env fallback no-ops on empty session id" case_pane_env_empty_sid_returns_skip
check "pane-env fallback resolves the real pane tty" case_pane_env_resolves_real_pane
check "native app self-test" case_native_app_self_test

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
