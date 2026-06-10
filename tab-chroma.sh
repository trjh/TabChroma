#!/bin/bash
# tab-chroma: iTerm2 visual feedback plugin for Claude Code
# Changes tab color, badge, and title based on Claude Code hook events

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# SHARE_DIR holds read-only assets (the script, themes, completions, VERSION).
# DATA_DIR holds writable runtime files (config.json, .state.json, .paused).
# Both default to SCRIPT_DIR for a plain git/curl install where everything
# lives together. The Homebrew wrapper and install.sh export TAB_CHROMA_SHARE
# and TAB_CHROMA_DATA to keep the read-only Cellar/share copy separate from the
# writable ~/.claude/hooks/tab-chroma data dir.
SHARE_DIR="${TAB_CHROMA_SHARE:-$SCRIPT_DIR}"
DATA_DIR="${TAB_CHROMA_DATA:-$SCRIPT_DIR}"

CONFIG="$DATA_DIR/config.json"
STATE="$DATA_DIR/.state.json"
PAUSED="$DATA_DIR/.paused"

# Shared cross-agent session registry (SQLite), read by menu-bar UIs that show
# one light per active Claude/Codex session. It lives OUTSIDE DATA_DIR on
# purpose: it is cross-session state shared by both agents, so it must survive a
# plugin reinstall/uninstall and not be nested under a Claude-specific path.
# Override with TAB_CHROMA_REGISTRY_DB (used by tests, like TAB_CHROMA_DATA).
REGISTRY_DB="${TAB_CHROMA_REGISTRY_DB:-$HOME/Library/Application Support/TabChroma/sessions.sqlite3}"

THEMES_DIR="$SHARE_DIR/themes"
VERSION_FILE="$SHARE_DIR/VERSION"

if [[ -r "$VERSION_FILE" ]]; then
  read -r VERSION < "$VERSION_FILE"
else
  VERSION="unknown"
fi

# ─── Terminal Detection ────────────────────────────────────────────────────────

detect_terminal() {
  if [ "$TERM_PROGRAM" = "iTerm.app" ]; then
    echo "iterm2"
  elif [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    echo "apple-terminal"
  elif [ -n "$KITTY_PID" ]; then
    echo "kitty"
  else
    echo "unsupported"
  fi
}

TERMINAL="$(detect_terminal)"

# ─── Terminal Device Resolution ──────────────────────────────────────────────
# Claude Code runs hooks with no controlling terminal, so /dev/tty is not
# available in the hook process (open fails with "device not configured").
# Walk up the process tree to the nearest ancestor that owns a real tty — the
# iTerm2 session — and target its device node directly. Same user owns that
# pts, so it is writable. Falls back to /dev/tty for the normal interactive
# CLI case (where $$ already has a controlling terminal on the first hop).
#
# Sets two globals in one walk:
#   TTY_DEVICE — first writable controlling tty found (for escape-sequence output)
#   TTY_PID    — nearest tty-owning ancestor that is NOT this hook process. In
#                hook mode the hook subtree is detached (no controlling tty), so
#                this resolves to the long-lived agent (Claude/Codex) process.
#                It is the session's liveness anchor (Phase 4): it dies on crash
#                or tab close but survives sleep, and is never a transient
#                per-invocation wrapper. Never the hook's own pid, so it cannot
#                be falsely pruned the moment this hook exits.
resolve_terminal_target() {
  local pid=$$ tt i=0
  TTY_DEVICE="/dev/tty"
  TTY_PID=""
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$i" -lt 12 ]; do
    tt="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$tt" ] && [ "$tt" != "??" ] && [ -w "/dev/$tt" ]; then
      [ "$TTY_DEVICE" = "/dev/tty" ] && TTY_DEVICE="/dev/$tt"
      if [ "$pid" != "$$" ]; then
        TTY_PID="$pid"
        return 0
      fi
    fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    i=$((i + 1))
  done

  # Fallback for detached hooks. Some agents (observed with codex) spawn the
  # hook reparented away from the agent process, so the ppid walk above never
  # reaches a tty-owning ancestor: TTY_DEVICE stays /dev/tty and TTY_PID empty,
  # leaving a row that can never be focused and never liveness-pruned (it lingers
  # on the TTL backstop). The hook still inherits the agent's
  # ITERM_SESSION_ID/TERM_SESSION_ID, and every process in that iTerm pane
  # carries it in its environment (readable via `ps -E`, same user). Find a
  # process in that pane that owns a real, writable tty and adopt its tty,
  # preferring the agent's own process (matched by comm) as the liveness anchor.
  if [ "$TTY_DEVICE" = "/dev/tty" ]; then
    resolve_via_pane_env "${ITERM_SESSION_ID:-$TERM_SESSION_ID}" "${TAB_CHROMA_AGENT:-}"
  fi
}

# Best-effort: map an iTerm pane session id ($1) to the pane's tty + a liveness
# pid, by scanning process environments. $2 is the preferred agent comm
# (claude/codex) used to pick the liveness anchor; any pane process on a real
# tty supplies the tty itself. Only called on the detached-hook fallback path,
# so the one-shot `ps -E` scan is off the common hook path.
resolve_via_pane_env() {
  local sid="$1" want="$2"
  [ -n "$sid" ] || return 1
  local pid tt comm rest any_tty="" any_pid=""
  while IFS=' ' read -r pid tt comm rest; do
    [ -n "$pid" ] && [ "$pid" != "$$" ] || continue
    [ -n "$tt" ] && [ "$tt" != "??" ] && [ -w "/dev/$tt" ] || continue
    case "$rest" in
      *"ITERM_SESSION_ID=$sid"*|*"TERM_SESSION_ID=$sid"*) ;;
      *) continue ;;
    esac
    # First pane-mate on a real tty pins the tty (all share the pane's tty).
    [ -z "$any_tty" ] && { any_tty="$tt"; any_pid="$pid"; }
    # Prefer the agent's own process as the durable liveness anchor.
    if [ -n "$want" ]; then
      case "$comm" in
        *"$want"*) TTY_DEVICE="/dev/$tt"; TTY_PID="$pid"; return 0 ;;
      esac
    fi
  done <<EOF
$(ps -E -A -o pid=,tty=,comm=,command= 2>/dev/null)
EOF
  if [ -n "$any_tty" ]; then
    TTY_DEVICE="/dev/$any_tty"
    TTY_PID="$any_pid"
    return 0
  fi
  return 1
}

resolve_terminal_target

# ─── iTerm2 Output Functions ───────────────────────────────────────────────────

set_tab_color() {
  local r=$1 g=$2 b=$3
  { printf '\033]6;1;bg;red;brightness;%s\a\033]6;1;bg;green;brightness;%s\a\033]6;1;bg;blue;brightness;%s\a' \
    "$r" "$g" "$b" > "$TTY_DEVICE"; } 2>/dev/null
}

reset_tab_color() {
  { printf '\033]6;1;bg;*;default\a' > "$TTY_DEVICE"; } 2>/dev/null
}

set_badge_color() {
  local r=$1 g=$2 b=$3
  if [ "$TERMINAL" = "iterm2" ]; then
    local hex
    hex="$(printf '%02x%02x%02x' "$r" "$g" "$b")"
    { printf '\033]1337;SetColors=badge=%s\a' "$hex" > "$TTY_DEVICE"; } 2>/dev/null
  fi
}

reset_badge_color() {
  if [ "$TERMINAL" = "iterm2" ]; then
    { printf '\033]1337;SetColors=badge=default\a' > "$TTY_DEVICE"; } 2>/dev/null
  fi
}

set_tab_title() {
  local title="$1"
  if [ "$TERMINAL" = "iterm2" ] || [ "$TERMINAL" = "apple-terminal" ]; then
    { printf '\033]0;%s\007' "$title" > "$TTY_DEVICE"; } 2>/dev/null
  fi
}

set_badge() {
  local text="$1"
  if [ "$TERMINAL" = "iterm2" ]; then
    if [ -z "$text" ]; then
      { printf '\033]1337;SetBadgeFormat=\a' > "$TTY_DEVICE"; } 2>/dev/null
    else
      { printf '\033]1337;SetBadgeFormat=%s\a' "$(printf '%s' "$text" | base64)" > "$TTY_DEVICE"; } 2>/dev/null
    fi
  fi
}

# ─── Config Helpers ───────────────────────────────────────────────────────────

get_active_theme() {
  python3 -c "import json; print(json.load(open('$CONFIG')).get('active_theme','default'))" 2>/dev/null
}

# ─── Ensure config exists ──────────────────────────────────────────────────────

ensure_config() {
  if [ ! -f "$CONFIG" ]; then
    mkdir -p "$DATA_DIR"
    cat > "$CONFIG" << 'EOF'
{
  "active_theme": "default",
  "enabled": true,
  "features": {
    "tab_color": true,
    "badge": false,
    "title": true
  },
  "states": {
    "session.start": true,
    "working": true,
    "done": true,
    "attention": true,
    "permission": true
  },
  "debounce_seconds": 2,
  "theme_rotation": [],
  "theme_rotation_mode": "off"
}
EOF
  fi
}

# ─── CLI Commands ──────────────────────────────────────────────────────────────

cmd_help() {
  cat << EOF
tab-chroma v$VERSION — iTerm2 visual feedback for Claude Code and Codex

USAGE:
  tab-chroma <command> [args]

CONTROLS:
  pause                 Disable color changes
  resume                Re-enable color changes
  toggle                Toggle pause state
  status                Show current config and state

THEMES:
  theme list            List installed themes
  theme use <name>      Switch active theme
  theme next            Cycle to next theme
  theme preview [name]  Preview all states (2s each)

FEATURES:
  badge on|off          Toggle iTerm2 badge
  title on|off          Toggle tab title updates
  color on|off          Toggle tab color changes

TESTING:
  test <state>          Manually trigger a state
                        States: working done attention permission session.start
  reset                 Reset tab to default color

SESSIONS:
  sessions list         Show active agent sessions in the shared registry
  sessions focus <key>  Raise iTerm2 and focus the session
  sessions prune        Remove sessions whose process is gone
  sessions clear        Remove all sessions
  sessions path         Print the registry database path

INFO:
  help                  Show this help
  version               Show version

SETUP:
  install               Register Claude Code and Codex hooks
  uninstall             Remove hooks, completions, and data files
EOF
}

cmd_status() {
  ensure_config
  local paused="false"
  [ -f "$PAUSED" ] && paused="true"

  python3 - << EOF
import json, os

config_path = "$CONFIG"
state_path = "$STATE"

try:
    config = json.load(open(config_path))
except Exception:
    config = {}

try:
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
except Exception:
    state = {}

print(f"tab-chroma v$VERSION")
print(f"")
print(f"paused:        $paused")
print(f"enabled:       {config.get('enabled', True)}")
print(f"active theme:  {config.get('active_theme', 'default')}")
print(f"last state:    {state.get('last_state', 'none')}")
print(f"")
print(f"features:")
features = config.get('features', {})
print(f"  tab_color:   {features.get('tab_color', True)}")
print(f"  badge:       {features.get('badge', True)}")
print(f"  title:       {features.get('title', True)}")
print(f"")
rotation_mode = config.get('theme_rotation_mode', 'off')
rotation = config.get('theme_rotation', [])
print(f"theme rotation: {rotation_mode}")
if rotation:
    print(f"  themes: {', '.join(rotation)}")
EOF
}

cmd_pause() {
  touch "$PAUSED"
  echo "tab-chroma paused"
}

cmd_resume() {
  rm -f "$PAUSED"
  echo "tab-chroma resumed"
}

cmd_toggle() {
  if [ -f "$PAUSED" ]; then
    cmd_resume
  else
    cmd_pause
  fi
}

cmd_theme_list() {
  ensure_config
  python3 - << EOF
import json, os

themes_dir = "$THEMES_DIR"
config_path = "$CONFIG"

try:
    active = json.load(open(config_path)).get("active_theme", "default")
except Exception:
    active = "default"

print("installed themes:")
print("")
for name in sorted(os.listdir(themes_dir)):
    theme_path = os.path.join(themes_dir, name, "theme.json")
    if not os.path.isfile(theme_path):
        continue
    try:
        t = json.load(open(theme_path))
    except Exception:
        continue
    display = t.get("display_name", name)
    desc = t.get("description", "")
    marker = "*" if name == active else " "
    print(f"  {marker} {name:<12} {display:<16} {desc}")
print("")
print("  (* = active)")
EOF
}

cmd_theme_use() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "usage: tab-chroma theme use <name>" >&2
    return 1
  fi
  if [ ! -d "$THEMES_DIR/$name" ]; then
    echo "theme not found: $name" >&2
    echo "run 'tab-chroma theme list' to see available themes" >&2
    return 1
  fi
  ensure_config
  python3 - << EOF
import json
config = json.load(open("$CONFIG"))
config["active_theme"] = "$name"
json.dump(config, open("$CONFIG", "w"), indent=2)
print(f"active theme set to: $name")
EOF
}

cmd_theme_next() {
  ensure_config
  python3 - << EOF
import json, os

themes_dir = "$THEMES_DIR"
config_path = "$CONFIG"

themes = sorted(
    e for e in os.listdir(themes_dir)
    if os.path.isfile(os.path.join(themes_dir, e, "theme.json"))
)
config = json.load(open(config_path))
current = config.get("active_theme", "default")
if current in themes:
    idx = (themes.index(current) + 1) % len(themes)
else:
    idx = 0
next_theme = themes[idx]
config["active_theme"] = next_theme
json.dump(config, open(config_path, "w"), indent=2)
print(f"active theme set to: {next_theme}")
EOF
}

cmd_theme_preview() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    ensure_config
    name="$(get_active_theme)"
  fi
  local theme_file="$THEMES_DIR/$name/theme.json"
  if [ ! -f "$theme_file" ]; then
    echo "theme not found: $name" >&2
    return 1
  fi
  echo "previewing theme: $name (2s per state)"
  for state in "working" "done" "attention" "permission" "session.start"; do
    echo "  -> $state"
    _apply_theme_state "$theme_file" "$state"
    sleep 2
  done
  echo "preview complete"
}

_apply_theme_state() {
  local theme_file="$1" state_name="$2"
  eval "$(python3 - "$theme_file" "$state_name" << 'PYEOF'
import json, sys

theme_file = sys.argv[1]
state_name = sys.argv[2]

try:
    theme = json.load(open(theme_file))
except Exception:
    print('ACTION="skip"')
    sys.exit(0)

state = theme.get("states", {}).get(state_name, {})
if not state:
    print('ACTION="skip"')
    sys.exit(0)

action = state.get("action", "color")
try:
    r = int(state.get("r", 0))
    g = int(state.get("g", 0))
    b = int(state.get("b", 0))
except (TypeError, ValueError):
    r = g = b = 0

if action == "reset":
    print('ACTION=reset')
else:
    print('ACTION=color')
    print(f'COLOR_R={r}')
    print(f'COLOR_G={g}')
    print(f'COLOR_B={b}')
PYEOF
  )"

  if [ "$ACTION" = "reset" ]; then
    reset_tab_color
    reset_badge_color
  elif [ "$ACTION" = "color" ]; then
    set_tab_color "$COLOR_R" "$COLOR_G" "$COLOR_B"
    set_badge_color "$COLOR_R" "$COLOR_G" "$COLOR_B"
  fi
}

cmd_test() {
  local state_name="$1"
  if [ -z "$state_name" ]; then
    echo "usage: tab-chroma test <state>" >&2
    echo "states: working done attention permission session.start" >&2
    return 1
  fi

  local valid_states="working done attention permission session.start"
  local valid=0
  for s in $valid_states; do
    [ "$s" = "$state_name" ] && valid=1
  done
  if [ $valid -eq 0 ]; then
    echo "unknown state: $state_name" >&2
    echo "valid states: $valid_states" >&2
    return 1
  fi

  ensure_config
  local theme_name
  theme_name="$(get_active_theme)"
  local theme_file="$THEMES_DIR/$theme_name/theme.json"

  if [ ! -f "$theme_file" ]; then
    theme_file="$THEMES_DIR/default/theme.json"
  fi

  echo "testing state: $state_name (theme: $theme_name)"
  _apply_theme_state "$theme_file" "$state_name"

  # Apply title and badge. theme_file/state_name/project_name are passed as
  # argv (not interpolated into the Python source) and the outputs go through
  # shlex.quote() so the eval below cannot execute their contents.
  local project_name
  project_name="$(basename "$PWD")"
  eval "$(python3 - "$theme_file" "$state_name" "$project_name" << 'PYEOF'
import json, shlex, sys
theme_file, state_name, project_name = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    theme = json.load(open(theme_file))
except Exception:
    theme = {}
state_cfg = theme.get("states", {}).get(state_name, {})
label = str(state_cfg.get("label", state_name))
print('TITLE_TEXT=' + shlex.quote(f"◉ {project_name}: {label}"))
print('BADGE_TEXT=' + shlex.quote(f"{project_name}\\n{label}"))
PYEOF
  )"
  [ -n "$TITLE_TEXT" ] && set_tab_title "$TITLE_TEXT"
  if [ -n "$BADGE_TEXT" ]; then
    set_badge "$BADGE_TEXT"
    # Set badge color AFTER text — iTerm2 resets it when badge format changes
    [ "$ACTION" = "color" ] && set_badge_color "$COLOR_R" "$COLOR_G" "$COLOR_B"
  fi
}

cmd_reset() {
  reset_tab_color
  reset_badge_color
  set_badge ""
  echo "tab color reset"
}

cmd_install() {
  local settings="$HOME/.claude/settings.json"
  # Register a stable command path. The Homebrew wrapper exports
  # TAB_CHROMA_HOOK_CMD pointing at bin/tab-chroma so hooks survive upgrades
  # instead of pinning a versioned Cellar path.
  local hook_cmd="${TAB_CHROMA_HOOK_CMD:-$SCRIPT_DIR/tab-chroma.sh}"
  local events="SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse Stop Notification PermissionRequest"
  local codex_events="SessionStart UserPromptSubmit PreToolUse PostToolUse Stop PermissionRequest"

  mkdir -p "$HOME/.claude"
  if [ ! -f "$settings" ]; then
    echo '{}' > "$settings"
  fi

  python3 - "$settings" "$hook_cmd" "TAB_CHROMA_AGENT=claude $hook_cmd" $events << 'PYEOF'
import json, sys

settings_path, needle, desired = sys.argv[1], sys.argv[2], sys.argv[3]
events = sys.argv[4:]

with open(settings_path) as f:
    cfg = json.load(f)

cfg.setdefault("hooks", {})
changed = False
for event in events:
    matchers = cfg["hooks"].setdefault(event, [{"matcher": "", "hooks": []}])
    # Find the catch-all matcher
    catch_all = next((m for m in matchers if m.get("matcher") == ""), None)
    if catch_all is None:
        catch_all = {"matcher": "", "hooks": []}
        matchers.append(catch_all)
    hooks = catch_all.setdefault("hooks", [])
    # Collapse any prior tab-chroma entry (plain OR agent-prefixed) down to the
    # single desired command, so reinstalling upgrades old plain entries to the
    # agent-tagged form without duplicating.
    tc = [h for h in hooks if needle in h.get("command", "")]
    non_tc = [h for h in hooks if needle not in h.get("command", "")]
    already_current = len(tc) == 1 and tc[0].get("command") == desired
    if not already_current:
        changed = True
    catch_all["hooks"] = non_tc + [{"type": "command", "command": desired}]

with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)

if changed:
    print(f"tab-chroma hooks registered in {settings_path}")
else:
    print("tab-chroma hooks already registered")
PYEOF

  if command -v codex >/dev/null 2>&1 || [ -d "$HOME/.codex" ]; then
    local codex_hooks="$HOME/.codex/hooks.json"
    mkdir -p "$HOME/.codex"
    if [ ! -f "$codex_hooks" ]; then
      echo '{"hooks":{}}' > "$codex_hooks"
    fi

    python3 - "$codex_hooks" "$hook_cmd" "TAB_CHROMA_AGENT=codex $hook_cmd" $codex_events << 'PYEOF'
import json, sys

hooks_path, needle, desired = sys.argv[1], sys.argv[2], sys.argv[3]
events = sys.argv[4:]

try:
    with open(hooks_path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

cfg.setdefault("hooks", {})
changed = False
for event in events:
    matchers = cfg["hooks"].setdefault(event, [])
    catch_all = next((m for m in matchers if m.get("matcher", "") in ("", "*")), None)
    if catch_all is None:
        catch_all = {"matcher": "", "hooks": []}
        matchers.append(catch_all)
    hooks = catch_all.setdefault("hooks", [])
    # Collapse any prior tab-chroma entry to the single desired (agent-tagged)
    # command, upgrading old plain entries without duplicating.
    tc = [h for h in hooks if needle in h.get("command", "")]
    non_tc = [h for h in hooks if needle not in h.get("command", "")]
    already_current = len(tc) == 1 and tc[0].get("command") == desired
    if not already_current:
        changed = True
    catch_all["hooks"] = non_tc + [{"type": "command", "command": desired}]

tmp = hooks_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
import os
os.replace(tmp, hooks_path)

if changed:
    print(f"tab-chroma Codex hooks registered in {hooks_path}")
else:
    print("tab-chroma Codex hooks already registered")
PYEOF
  else
    echo "Codex not found; skipping Codex hook registration."
  fi

  # Set up shell alias and completions
  local zshrc="$HOME/.zshrc"
  local alias_line="alias tab-chroma='$hook_cmd'"
  if ! grep -qF "alias tab-chroma=" "$zshrc" 2>/dev/null; then
    echo "" >> "$zshrc"
    echo "# tab-chroma" >> "$zshrc"
    echo "$alias_line" >> "$zshrc"
    echo "alias added to $zshrc (run: source ~/.zshrc)"
  fi

  # Tab reset on exit is handled by the SessionEnd hook (registered above).
  # Older versions shimmed a claude() shell wrapper to do this; remove it if
  # present so upgrading installs don't keep shadowing the `claude` command.
  local wrapper_marker="# tab-chroma: reset tab on claude exit"
  if grep -qF "$wrapper_marker" "$zshrc" 2>/dev/null; then
    python3 - "$zshrc" << 'PYEOF'
import re, sys
zshrc = sys.argv[1]
with open(zshrc) as f:
    content = f.read()
content = re.sub(
    r'\n# tab-chroma: reset tab on claude exit\nclaude\(\) \{\n  command claude "\$@"\n  tab-chroma reset > /dev/null 2>&1\n\}\n?',
    '', content)
with open(zshrc, "w") as f:
    f.write(content)
PYEOF
    echo "removed legacy claude() wrapper from $zshrc (run: source ~/.zshrc)"
  fi

  local comp_dir="$HOME/.bash_completion.d"
  local comp_src="$SHARE_DIR/completions/tab-chroma.bash"
  if [ -f "$comp_src" ]; then
    mkdir -p "$comp_dir"
    cp "$comp_src" "$comp_dir/tab-chroma"
    echo "completions installed to $comp_dir/tab-chroma"
  fi
}

cmd_uninstall() {
  local settings="$HOME/.claude/settings.json"
  local install_dir="$SCRIPT_DIR"
  local hook_cmd="${TAB_CHROMA_HOOK_CMD:-$SCRIPT_DIR/tab-chroma.sh}"

  read -r -p "Remove tab-chroma completely? This will remove all files and hooks. [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi

  echo "Removing Claude hooks from $settings..."
  # Match on every path tab-chroma may have registered: the share/script dir,
  # the writable data dir, and the stable hook command (Homebrew wrapper).
  python3 - "$settings" "$install_dir" "$DATA_DIR" "$hook_cmd" << 'PYEOF'
import json, os, sys
settings_path = sys.argv[1]
needles = [n for n in sys.argv[2:] if n]
if not os.path.exists(settings_path):
    print("  settings.json not found, skipping"); sys.exit(0)
try:
    cfg = json.load(open(settings_path))
except Exception as e:
    print(f"  error reading settings: {e}"); sys.exit(0)
changed = False
for event, entries in cfg.get("hooks", {}).items():
    for entry in entries:
        orig = list(entry.get("hooks", []))
        entry["hooks"] = [h for h in orig
                          if not any(n in h.get("command", "") for n in needles)]
        if len(entry["hooks"]) != len(orig):
            changed = True
if changed:
    tmp = settings_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2); f.write("\n")
    os.replace(tmp, settings_path)
    print("  Removed tab-chroma hook entries.")
else:
    print("  No tab-chroma hooks found in settings.")
PYEOF

  local codex_hooks="$HOME/.codex/hooks.json"
  echo "Removing Codex hooks from $codex_hooks..."
  python3 - "$codex_hooks" "$install_dir" "$DATA_DIR" "$hook_cmd" << 'PYEOF'
import json, os, sys
hooks_path = sys.argv[1]
needles = [n for n in sys.argv[2:] if n]
if not os.path.exists(hooks_path):
    print("  hooks.json not found, skipping"); sys.exit(0)
try:
    cfg = json.load(open(hooks_path))
except Exception as e:
    print(f"  error reading hooks.json: {e}"); sys.exit(0)
changed = False
for event, entries in cfg.get("hooks", {}).items():
    for entry in entries:
        orig = list(entry.get("hooks", []))
        entry["hooks"] = [h for h in orig
                          if not any(n in h.get("command", "") for n in needles)]
        if len(entry["hooks"]) != len(orig):
            changed = True
if changed:
    tmp = hooks_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2); f.write("\n")
    os.replace(tmp, hooks_path)
    print("  Removed tab-chroma Codex hook entries.")
else:
    print("  No tab-chroma Codex hooks found.")
PYEOF

  if [ "$TERM_PROGRAM" = "iTerm.app" ]; then
    printf '\033]6;1;bg;*;default\a' > "$TTY_DEVICE"
    printf '\033]1337;SetBadgeFormat=\a' > "$TTY_DEVICE"
    echo "Tab color reset and badge cleared."
  fi

  echo "Removing completions..."
  rm -f "$HOME/.bash_completion.d/tab-chroma"
  rm -f "$HOME/.config/fish/completions/tab-chroma.fish"

  echo "Removing shell entries from ~/.zshrc..."
  python3 - "$HOME/.zshrc" << 'PYEOF'
import sys, re
zshrc = sys.argv[1]
try:
    with open(zshrc) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(0)
# Remove alias block: "# tab-chroma\nalias tab-chroma=..."
content = re.sub(r'\n# tab-chroma\nalias tab-chroma=.*\n?', '', content)
# Remove wrapper block (5 lines after marker)
content = re.sub(
    r'\n# tab-chroma: reset tab on claude exit\nclaude\(\) \{\n  command claude "\$@"\n  tab-chroma reset > /dev/null 2>&1\n\}\n?',
    '', content
)
with open(zshrc, 'w') as f:
    f.write(content)
print("  Removed tab-chroma entries from ~/.zshrc")
PYEOF

  echo ""
  # Always remove the writable data dir (config/state/paused).
  if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ]; then
    echo "Removing data dir $DATA_DIR..."
    rm -rf "$DATA_DIR"
  fi
  # The shared session registry lives outside DATA_DIR and may still be used by
  # a sibling agent install, so it is intentionally left in place.
  if [ -f "$REGISTRY_DB" ]; then
    echo "Leaving shared session registry: $REGISTRY_DB"
    echo "  (remove it manually with: rm -f '$REGISTRY_DB'*)"
  fi
  # Remove the install dir only for a self-contained git/curl install. For a
  # Homebrew install the script lives in a brew-managed share dir, so leave it
  # to `brew uninstall`.
  if [ "$install_dir" = "$DATA_DIR" ]; then
    echo "Done. tab-chroma has been uninstalled."
  else
    echo "Done. To remove the package files, run: brew uninstall tab-chroma"
  fi
}

cmd_feature_toggle() {
  local feature="$1" value="$2"
  local key
  case "$feature" in
    badge) key="badge";;
    title) key="title";;
    color) key="tab_color";;
    *) echo "unknown feature: $feature" >&2; return 1;;
  esac
  if [ "$value" != "on" ] && [ "$value" != "off" ]; then
    echo "usage: tab-chroma $feature on|off" >&2
    return 1
  fi
  ensure_config
  local bool_val
  [ "$value" = "on" ] && bool_val="True" || bool_val="False"
  python3 - << EOF
import json
config = json.load(open("$CONFIG"))
config.setdefault("features", {})["$key"] = $bool_val
json.dump(config, open("$CONFIG", "w"), indent=2)
print(f"$feature: $value")
EOF

  # Immediately apply visual effect when disabling
  if [ "$value" = "off" ]; then
    case "$feature" in
      badge) set_badge ""; reset_badge_color;;
      color) reset_tab_color;;
    esac
  fi
  true
}

# ─── CLI Routing ───────────────────────────────────────────────────────────────

cmd_sessions() {
  local sub="${1:-list}"
  shift || true
  case "$sub" in
    path)
      echo "$REGISTRY_DB"
      ;;
    list|prune|clear|focus)
      TAB_CHROMA_REGISTRY_DB="$REGISTRY_DB" python3 - "$sub" "$@" << 'PYEOF'
import os, subprocess, sys, time
sub = sys.argv[1]
args = sys.argv[2:]
db = os.environ.get("TAB_CHROMA_REGISTRY_DB", "")
if not db or not os.path.exists(db):
    print("No session registry yet (no agent sessions recorded).")
    sys.exit(0 if sub != "focus" else 1)
import sqlite3
now = int(time.time())
con = sqlite3.connect(db, timeout=1.0)
con.row_factory = sqlite3.Row

def has_column(name):
    try:
        return any(row[1] == name for row in con.execute("PRAGMA table_info(sessions)"))
    except sqlite3.OperationalError:
        return False

_start_cache = {}

def ps_start(pid):
    key = str(pid)
    if key in _start_cache:
        return _start_cache[key]
    try:
        out = subprocess.run(
            ["/bin/ps", "-o", "lstart=", "-p", key],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=2).stdout
    except Exception:
        out = ""
    val = " ".join(out.split())
    _start_cache[key] = val
    return val

def _norm_lstart(s):
    # Locale/order-tolerant key for a ps -o lstart= string (see the hook writer
    # _norm_lstart). Keys on the start instant, not its locale rendering.
    t = s.split()
    return tuple(sorted(t[1:])) if len(t) > 1 else tuple(sorted(t))

def pid_alive(pid, start):
    # Mirror of the hook writer's check: alive iff the PID exists and, when both
    # start instants are known, they still match (guards against PID reuse).
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    except Exception:
        return False
    if not start:
        return True
    cur = ps_start(pid)
    return (not cur) or _norm_lstart(cur) == _norm_lstart(start)

def session_row(key):
    tty_expr = "tty_device" if has_column("tty_device") else "'' AS tty_device"
    return con.execute(
        f"SELECT session_key, agent, agent_session_id, state, label, cwd, terminal, {tty_expr} "
        "FROM sessions WHERE session_key = ? OR agent_session_id = ? LIMIT 1",
        (key, key),
    ).fetchone()

def notify(text):
    # Best-effort macOS banner so a SwiftBar background click (terminal=false) is
    # never silent on failure — the click otherwise gives no UI, which reads as
    # "nothing happened". `display notification` controls no other app, so it is
    # NOT gated by Automation TCC and still fires when *iTerm* control is the
    # thing being denied.
    try:
        subprocess.run(
            ["/usr/bin/osascript", "-e",
             'on run a\ndisplay notification (item 1 of a) with title "TabChroma"\nend run',
             text],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except Exception:
        pass

def focus_iterm(row):
    # Match on tty_device only. iTerm2's AppleScript `id of s` is a different
    # GUID from `ITERM_SESSION_ID`, so the stored `terminal` cannot be matched
    # this way; the resolved tty path (e.g. /dev/ttys003) is the reliable key
    # and also pins the exact pane within a split.
    tty = (row["tty_device"] or "").strip()
    label = row["label"] or row["cwd"] or row["session_key"]
    if not tty:
        msg = f"No terminal recorded yet for {label} — it becomes focusable after its next activity."
        notify(msg)
        print(msg, file=sys.stderr)
        subprocess.run(["/usr/bin/open", "-a", "iTerm"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 1
    # Fetch each tab's session ttys in ONE Apple Event (`tty of sessions of t`)
    # rather than one round-trip per session (`tty of s`). On a busy machine the
    # per-session form could blow past the timeout — its cost scales with the
    # total session count (every split pane), while the bulk form scales with the
    # tab count and is ~2x faster in practice. The list returned is parallel to
    # `sessions of t`, so the matching index resolves the session to select.
    script = r'''
on run argv
  set targetTty to item 1 of argv
  tell application "iTerm2"
    activate
    repeat with w in windows
      repeat with t in tabs of w
        set ttys to tty of sessions of t
        repeat with i from 1 to (count of ttys)
          if (item i of ttys) is targetTty then
            try
              select w
            end try
            try
              select t
            end try
            try
              select (item i of sessions of t)
            end try
            return "focused"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "not-found"
end run
'''
    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", script, tty],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            # Generous margin: the scan is sub-second, but iTerm can stall Apple
            # Events transiently (heavy output, app launch). Focus runs in the
            # background (terminal=false), so a longer ceiling blocks nothing.
            timeout=10,
        )
    except Exception as e:
        msg = f"Couldn't run osascript to focus {label}: {e}"
        notify(msg)
        print(msg, file=sys.stderr)
        subprocess.run(["/usr/bin/open", "-a", "iTerm"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 1
    if result.returncode == 0 and result.stdout.strip() == "focused":
        print(f"Focused {label}")
        return 0
    # Loud failure: a notification (so a background SwiftBar click isn't silent)
    # plus stderr, with a TCC-specific, actionable hint when iTerm control is
    # denied — the common first-run case.
    err = (result.stderr or "").strip()
    low = err.lower()
    if result.returncode != 0 and ("-1743" in err or "not author" in low
                                   or "not allowed" in low or "assistive" in low):
        msg = ("iTerm control is blocked. Allow it under System Settings > Privacy "
               "& Security > Automation > SwiftBar > iTerm, then click the session again.")
    elif result.stdout.strip() == "not-found":
        msg = f"Couldn't find {label}'s tab ({tty}) — it may have been closed."
    else:
        msg = f"Couldn't focus {label} ({err or 'unknown error'})."
    notify(msg)
    print(msg, file=sys.stderr)
    subprocess.run(["/usr/bin/open", "-a", "iTerm"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 1

try:
    con.execute("PRAGMA busy_timeout=1000")
    if sub == "clear":
        n = con.execute("DELETE FROM sessions").rowcount
        con.commit()
        print(f"Cleared {n} session(s).")
    elif sub == "prune":
        # Liveness sweep, mirroring the hook writer: drop rows whose process is
        # gone, plus PID-less rows past their TTL backstop. Each column is
        # probed independently so a partially-migrated DB (session_pid added but
        # pid_start not yet, or vice versa) still prunes instead of erroring.
        pid_sel = "session_pid" if has_column("session_pid") else "NULL AS session_pid"
        start_sel = "pid_start" if has_column("pid_start") else "'' AS pid_start"
        n = 0
        for srow in con.execute(
                f"SELECT session_key, {pid_sel}, {start_sel}, expires_at FROM sessions").fetchall():
            skey, spid, sstart, sexp = srow["session_key"], srow["session_pid"], srow["pid_start"], srow["expires_at"]
            dead = False
            if spid:
                dead = not pid_alive(spid, sstart or "")
            if not dead and sexp is not None and sexp < now:
                dead = True
            if dead:
                con.execute("DELETE FROM sessions WHERE session_key = ?", (skey,))
                n += 1
        con.commit()
        print(f"Pruned {n} dead session(s).")
    elif sub == "focus":
        if not args:
            print("usage: tab-chroma sessions focus <session_key>", file=sys.stderr)
            sys.exit(2)
        row = session_row(args[0])
        if row is None:
            print(f"No session found for key: {args[0]}", file=sys.stderr)
            sys.exit(1)
        sys.exit(focus_iterm(row))
    else:
        rows = con.execute(
            "SELECT session_key, agent, state, label, cwd, updated_at FROM sessions "
            "WHERE expires_at IS NULL OR expires_at >= ? "
            "ORDER BY updated_at DESC", (now,)).fetchall()
        if not rows:
            print("No active sessions.")
            sys.exit(0)
        print(f"{'KEY':<45} {'AGENT':<7} {'STATE':<10} {'LABEL':<18} {'AGE':<6} CWD")
        for key, agent, state, label, cwd, upd in rows:
            age = now - (upd or now)
            age_s = f"{age}s" if age < 60 else (f"{age//60}m" if age < 3600 else f"{age//3600}h")
            print(f"{key:<45} {agent:<7} {state:<10} {(label or ''):<18} {age_s:<6} {cwd or ''}")
except sqlite3.OperationalError as e:
    print(f"registry error: {e}", file=sys.stderr)
    sys.exit(1)
finally:
    con.close()
PYEOF
      ;;
    *)
      echo "unknown sessions subcommand: $sub" >&2
      echo "usage: tab-chroma sessions [list|focus <key>|prune|clear|path]" >&2
      return 1
      ;;
  esac
}

route_cli() {
  local cmd="$1"
  shift || true

  case "$cmd" in
    pause)   cmd_pause;;
    resume)  cmd_resume;;
    toggle)  cmd_toggle;;
    status)  cmd_status;;
    reset)   cmd_reset;;
    version) echo "tab-chroma v$VERSION";;
    help|--help|-h) cmd_help;;

    theme)
      local subcmd="${1:-list}"
      shift || true
      case "$subcmd" in
        list)    cmd_theme_list;;
        use)     cmd_theme_use "$@";;
        next)    cmd_theme_next;;
        preview) cmd_theme_preview "$@";;
        *)       echo "unknown theme subcommand: $subcmd" >&2; return 1;;
      esac
      ;;

    badge) cmd_feature_toggle "badge" "$@";;
    title) cmd_feature_toggle "title" "$@";;
    color) cmd_feature_toggle "color" "$@";;

    test) cmd_test "$@";;

    sessions) cmd_sessions "$@";;

    install)   cmd_install;;
    uninstall) cmd_uninstall;;

    *)
      echo "unknown command: $cmd" >&2
      echo "run 'tab-chroma help' for usage" >&2
      return 1
      ;;
  esac
}

# ─── Hook Event Processing ─────────────────────────────────────────────────────

process_hook() {
  # Only proceed for iTerm2 (or apple-terminal for title-only)
  if [ "$TERMINAL" = "unsupported" ] || [ "$TERMINAL" = "kitty" ]; then
    exit 0
  fi

  # Fast exit: drain stdin so hook runner doesn't block, then bail
  if [ -f "$PAUSED" ]; then
    cat > /dev/null
    exit 0
  fi

  ensure_config

  # Read stdin (hook JSON input)
  local INPUT
  INPUT="$(cat)"

  # Run consolidated Python block: parse input, check config, debounce, resolve theme
  eval "$(TAB_CHROMA_INPUT="$INPUT" \
  TAB_CHROMA_CONFIG="$CONFIG" \
  TAB_CHROMA_STATE="$STATE" \
  TAB_CHROMA_THEMES="$THEMES_DIR" \
  TAB_CHROMA_AGENT="${TAB_CHROMA_AGENT:-}" \
  TAB_CHROMA_REGISTRY_DB="$REGISTRY_DB" \
  TAB_CHROMA_TTY_DEVICE="$TTY_DEVICE" \
  TAB_CHROMA_TTY_PID="$TTY_PID" \
  python3 - << 'PYEOF'
import sys, json, os, time, shlex, subprocess

input_data = os.environ.get("TAB_CHROMA_INPUT", "")
config_path = os.environ.get("TAB_CHROMA_CONFIG", "")
state_path = os.environ.get("TAB_CHROMA_STATE", "")
themes_dir = os.environ.get("TAB_CHROMA_THEMES", "")

# --- Parse hook input ---
try:
    event_data = json.loads(input_data)
except Exception:
    print('ACTION="skip"')
    sys.exit(0)

event = event_data.get("hook_event_name", "")
cwd = event_data.get("cwd", "")
session_id = event_data.get("session_id", "")

notification_type = event_data.get("message", "").lower() if event == "Notification" else ""

# --- Map event -> state ---
state_map = {
    "SessionStart":      "session.start",
    "UserPromptSubmit":  "working",
    "PreToolUse":        "working",
    "Stop":              "done",
    "PostToolUse":       "working",
}

state_name = state_map.get(event, "")

if event == "Notification":
    if "permission" in notification_type or "approval" in notification_type:
        state_name = "permission"
    else:
        # Any other notification (e.g. Claude idle / waiting for input) is an
        # attention cue. Stop already covers the "done" case, so this won't
        # fight it.
        state_name = "attention"
elif event == "PermissionRequest":
    state_name = "permission"
elif event == "SessionEnd":
    # Reuse the session.start "reset" action so the tab clears when the agent
    # exits — replaces the old claude() shell wrapper.
    state_name = "session.start"

if not state_name:
    print('ACTION="skip"')
    sys.exit(0)

# --- Load config ---
try:
    config = json.load(open(config_path))
except Exception:
    config = {}

if not config.get("enabled", True):
    print('ACTION="skip"')
    sys.exit(0)

# Check per-state enable
if not config.get("states", {}).get(state_name, True):
    print('ACTION="skip"')
    sys.exit(0)

# --- Load state ---
try:
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
except Exception:
    state = {}

# --- Debounce ---
now = time.time()
last_time = state.get("last_state_time", 0)
last_state = state.get("last_state", "")
debounce = config.get("debounce_seconds", 2)
# SessionEnd bypasses debounce: it maps to the session.start state, so a quick
# SessionStart -> SessionEnd would otherwise be debounced and skip both the tab
# reset and the session_themes pin cleanup below.
urgent = state_name in ("attention", "permission") or event == "SessionEnd"

if state_name == last_state and (now - last_time) < debounce and not urgent:
    print('ACTION="skip"')
    sys.exit(0)

# --- Resolve theme ---
rotation_mode = config.get("theme_rotation_mode", "off")
rotation = config.get("theme_rotation", [])
rotation_index = state.get("rotation_index", 0)

# Per-session theme pinning
session_themes = state.get("session_themes", {})

if rotation_mode != "off" and rotation:
    if rotation_mode == "random":
        import random
        theme_name = random.choice(rotation)
    elif rotation_mode == "round-robin":
        theme_name = rotation[rotation_index % len(rotation)]
        if state_name == "session.start":
            rotation_index = (rotation_index + 1) % len(rotation)
    else:
        theme_name = config.get("active_theme", "default")
else:
    theme_name = config.get("active_theme", "default")

# Pin theme to session
if session_id and event == "SessionStart":
    session_themes[session_id] = theme_name
elif session_id and session_id in session_themes:
    theme_name = session_themes[session_id]

# Drop the pin when the session ends so the map doesn't grow unbounded
if session_id and event == "SessionEnd":
    session_themes.pop(session_id, None)

# --- Load theme ---
theme_file = os.path.join(themes_dir, theme_name, "theme.json")
if not os.path.exists(theme_file):
    theme_file = os.path.join(themes_dir, "default", "theme.json")

try:
    theme = json.load(open(theme_file))
except Exception:
    print('ACTION="skip"')
    sys.exit(0)

state_config = theme.get("states", {}).get(state_name, {})
if not state_config:
    print('ACTION="skip"')
    sys.exit(0)

action = state_config.get("action", "color")
try:
    r = int(state_config.get("r", 0))
    g = int(state_config.get("g", 0))
    b = int(state_config.get("b", 0))
except (TypeError, ValueError):
    r = g = b = 0
label = str(state_config.get("label", state_name))

# --- Compute title and badge ---
project_name = os.path.basename(cwd) if cwd else ""

features = config.get("features", {})
do_color = features.get("tab_color", True)
do_title = features.get("title", True)
do_badge = features.get("badge", True)

title_text = ""
badge_text = ""
if do_title and project_name:
    title_text = f"◉ {project_name}: {state_name}"
if do_badge and project_name:
    badge_text = f"{project_name}\\n{label}"

# --- Output bash variables ---
# Values that originate from untrusted input (the working-directory name in
# title_text/badge_text, the label from a theme file) are passed through
# shlex.quote() so the eval in the calling shell cannot execute them.
if action == "reset":
    print('ACTION=reset')
elif do_color:
    print('ACTION=color')
    print(f'COLOR_R={r}')
    print(f'COLOR_G={g}')
    print(f'COLOR_B={b}')
else:
    print('ACTION=title_only')

print('DO_TITLE=' + ('true' if do_title else 'false'))
print('DO_BADGE=' + ('true' if do_badge else 'false'))
print('TITLE_TEXT=' + shlex.quote(title_text))
print('BADGE_TEXT=' + shlex.quote(badge_text))
print('STATE_NAME=' + shlex.quote(state_name))

# --- Save state atomically ---
state["last_state"] = state_name
state["last_state_time"] = now
state["session_themes"] = session_themes
state["rotation_index"] = rotation_index

tmp_path = state_path + ".tmp"
with open(tmp_path, "w") as f:
    json.dump(state, f)
os.replace(tmp_path, state_path)

# --- Shared session registry (best-effort) ---
# Records one row per live agent session for menu-bar UIs. This is wrapped so a
# registry failure (locked DB, missing dir, no sqlite3) can NEVER break the
# hook: nothing here writes to stdout, and any exception is swallowed.
try:
    import sqlite3
    db_path = os.environ.get("TAB_CHROMA_REGISTRY_DB", "")
    if db_path:
        agent = (os.environ.get("TAB_CHROMA_AGENT") or "").strip() or "claude"
        terminal = os.environ.get("ITERM_SESSION_ID") or os.environ.get("TERM_SESSION_ID") or ""
        tty_device = os.environ.get("TAB_CHROMA_TTY_DEVICE", "")

        # Stable per-session key; fall back to a composite when no session id.
        if session_id:
            session_key = f"{agent}:{session_id}"
        else:
            session_key = f"{agent}:{cwd}:{terminal}"

        # Phase 4 liveness anchor: the agent (Claude/Codex) PID, resolved by
        # the tree-walk in resolve_terminal_target. While it is alive the row
        # never expires on inactivity — the lights stay a durable map of which
        # sessions are still open. A recorded start time guards against PID
        # reuse across a reboot (sleep leaves PIDs intact).
        tty_pid_raw = (os.environ.get("TAB_CHROMA_TTY_PID") or "").strip()
        _start_cache = {}

        def _ps_start(pid):
            # Stable process start-time string; compared verbatim, never parsed.
            key = str(pid)
            if key in _start_cache:
                return _start_cache[key]
            try:
                out = subprocess.run(
                    ["/bin/ps", "-o", "lstart=", "-p", key],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    text=True, timeout=2).stdout
            except Exception:
                out = ""
            val = " ".join(out.split())
            _start_cache[key] = val
            return val

        def _norm_lstart(s):
            # Locale/order-tolerant key for a ps -o lstart= string. ps formats
            # lstart per the caller locale ("Wed 3 Jun ..." vs "Wed Jun 3 ..."),
            # so a raw compare wrongly reports a live PID as recycled when a prune
            # runs under a different locale than the writer. Drop the weekday and
            # compare the remaining tokens as a sorted set: keys on the instant.
            # (No apostrophes here: this block runs inside eval "$(... )", where
            # bash 3.2 mis-parses a single quote even in a quoted heredoc.)
            t = s.split()
            return tuple(sorted(t[1:])) if len(t) > 1 else tuple(sorted(t))

        def _pid_alive(pid, start):
            # Alive iff the PID exists AND (when both start instants are known)
            # its start instant still matches. Biased against false-dead: an
            # unverifiable start time trusts kill(0) rather than pruning a row.
            if not pid:
                return False
            try:
                os.kill(int(pid), 0)
            except ProcessLookupError:
                return False
            except PermissionError:
                pass
            except Exception:
                return False
            if not start:
                return True
            cur = _ps_start(pid)
            return (not cur) or _norm_lstart(cur) == _norm_lstart(start)

        session_pid = None
        pid_start = ""
        if tty_pid_raw.isdigit() and _pid_alive(tty_pid_raw, ""):
            session_pid = int(tty_pid_raw)
            pid_start = _ps_start(session_pid)

        # Registry state + fallback TTL backstop (seconds). For PID-anchored
        # rows the TTL is unused (expires_at is NULL); it is the lifecycle only
        # for rows with no usable PID, and the brief SessionEnd afterglow.
        now_i = int(now)
        if event == "SessionEnd":
            reg_state, ttl = "ended", 60                 # ~60s afterglow, then swept
        elif state_name == "session.start":
            reg_state, ttl = "starting", 600             # 10 min if no activity follows
        elif state_name == "done":
            reg_state, ttl = "done", 12 * 3600           # green until exit; 12h backstop
        else:
            reg_state, ttl = state_name, 2 * 3600        # working/permission/attention

        # A live, PID-anchored session persists until its process is gone, so
        # it never expires on idle time alone. SessionEnd keeps its short TTL so
        # the ⚫ afterglow still fades; PID-less rows keep the TTL backstop.
        if session_pid is not None and event != "SessionEnd":
            expires_at = None
        else:
            expires_at = now_i + ttl

        # Only create a parent dir when the path actually has one. A
        # basename-only override (e.g. TAB_CHROMA_REGISTRY_DB=sessions.sqlite3)
        # has an empty dirname, and os.makedirs("") would raise and silently
        # skip the whole write under the surrounding try/except.
        db_dir = os.path.dirname(db_path)
        if db_dir:
            os.makedirs(db_dir, exist_ok=True)
        con = sqlite3.connect(db_path, timeout=0.25)
        try:
            con.execute("PRAGMA journal_mode=WAL")
            con.execute("PRAGMA busy_timeout=250")
            con.execute("PRAGMA synchronous=NORMAL")
            con.execute("""CREATE TABLE IF NOT EXISTS sessions (
                session_key TEXT PRIMARY KEY,
                agent TEXT NOT NULL,
                agent_session_id TEXT,
                state TEXT NOT NULL,
                label TEXT,
                cwd TEXT,
                terminal TEXT,
                theme TEXT,
                color_r INTEGER, color_g INTEGER, color_b INTEGER,
                started_at INTEGER,
                updated_at INTEGER NOT NULL,
                expires_at INTEGER,
                session_pid INTEGER,
                pid_start TEXT,
                metadata_json TEXT)""")
            try:
                columns = {row[1] for row in con.execute("PRAGMA table_info(sessions)")}
                if "tty_device" not in columns:
                    con.execute("ALTER TABLE sessions ADD COLUMN tty_device TEXT")
                if "session_pid" not in columns:
                    con.execute("ALTER TABLE sessions ADD COLUMN session_pid INTEGER")
                if "pid_start" not in columns:
                    con.execute("ALTER TABLE sessions ADD COLUMN pid_start TEXT")
            except Exception:
                pass
            con.execute("CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at)")
            con.execute("BEGIN IMMEDIATE")
            # started_at is intentionally NOT in the UPDATE set, so it is kept
            # from the original INSERT across the whole session lifetime.
            con.execute("""INSERT INTO sessions
                (session_key, agent, agent_session_id, state, label, cwd, terminal, tty_device,
                 theme, color_r, color_g, color_b, started_at, updated_at, expires_at,
                 session_pid, pid_start, metadata_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(session_key) DO UPDATE SET
                  state=excluded.state, label=excluded.label, cwd=excluded.cwd,
                  terminal=excluded.terminal, tty_device=excluded.tty_device, theme=excluded.theme,
                  color_r=excluded.color_r, color_g=excluded.color_g, color_b=excluded.color_b,
                  updated_at=excluded.updated_at, expires_at=excluded.expires_at,
                  session_pid=excluded.session_pid, pid_start=excluded.pid_start""",
                (session_key, agent, session_id, reg_state, project_name or label, cwd,
                 terminal, tty_device, theme_name, r, g, b, now_i, now_i, expires_at,
                 session_pid, pid_start, None))
            # Liveness sweep (Phase 4): drop rows whose process is gone, plus
            # PID-less rows past their TTL backstop. Replaces the old purely
            # time-based prune so live sessions survive arbitrarily long idle
            # gaps (a closed laptop) and dead ones (crash, tab close) clear out.
            for skey, spid, sstart, sexp in con.execute(
                    "SELECT session_key, session_pid, pid_start, expires_at "
                    "FROM sessions").fetchall():
                dead = False
                if spid:
                    dead = not _pid_alive(spid, sstart or "")
                if not dead and sexp is not None and sexp < now_i:
                    dead = True
                if dead:
                    con.execute("DELETE FROM sessions WHERE session_key = ?", (skey,))
            con.commit()
        finally:
            con.close()
except Exception:
    pass

PYEOF
  )"

  # Apply visual changes
  case "$ACTION" in
    reset)
      reset_tab_color
      ;;
    color)
      if [ "$TERMINAL" = "iterm2" ]; then
        set_tab_color "$COLOR_R" "$COLOR_G" "$COLOR_B"
      fi
      ;;
    title_only|"")
      # color disabled, fall through to title/badge
      ;;
    skip)
      exit 0
      ;;
  esac

  if [ "$DO_TITLE" = "true" ] && [ -n "$TITLE_TEXT" ]; then
    set_tab_title "$TITLE_TEXT"
  fi

  if [ "$DO_BADGE" = "true" ]; then
    if [ "$ACTION" = "reset" ]; then
      set_badge ""
      reset_badge_color
    elif [ -n "$BADGE_TEXT" ]; then
      set_badge "$BADGE_TEXT"
      # Set badge color AFTER text — iTerm2 resets it when badge format changes
      if [ "$ACTION" = "color" ]; then
        set_badge_color "$COLOR_R" "$COLOR_G" "$COLOR_B"
      fi
    fi
  fi
  true
}

# ─── Entry Point ───────────────────────────────────────────────────────────────

if [ $# -gt 0 ]; then
  # CLI mode
  route_cli "$@"
elif [ -t 0 ]; then
  # Interactive terminal with no args — show help
  cmd_help
else
  # Hook mode — stdin has JSON from Claude Code
  process_hook
fi
