#!/bin/bash
# tab-chroma uninstaller

INSTALL_DIR="$HOME/.claude/hooks/tab-chroma"
SETTINGS_FILE="$HOME/.claude/settings.json"
CODEX_HOOKS_FILE="$HOME/.codex/hooks.json"

echo "tab-chroma uninstaller"
echo ""

# Allow --yes / -y to skip confirmation (used by `tab-chroma uninstall`)
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
  confirm="y"
else
  read -r -p "Remove tab-chroma completely? This will remove all files and hooks. [y/N] " confirm
fi

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ─── 1. Remove hooks from settings.json ───────────────────────────────────────

echo "Removing hooks from $SETTINGS_FILE..."

python3 - << EOF
import json, os, sys

settings_path = "$SETTINGS_FILE"
install_dir = "$INSTALL_DIR"

if not os.path.exists(settings_path):
    print("  settings.json not found, skipping")
    sys.exit(0)

try:
    settings = json.load(open(settings_path))
except Exception as e:
    print(f"  error reading settings: {e}")
    sys.exit(0)

hooks = settings.get("hooks", {})
changed = False

for event, entries in hooks.items():
    for entry in entries:
        original = list(entry.get("hooks", []))
        entry["hooks"] = [
            h for h in original
            if install_dir not in h.get("command", "")
        ]
        if len(entry["hooks"]) != len(original):
            changed = True

if changed:
    tmp_path = settings_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, settings_path)
    print("  Removed tab-chroma hook entries.")
else:
    print("  No tab-chroma hooks found in settings.")
EOF

# ─── 2. Remove Codex hooks ────────────────────────────────────────────────────

echo "Removing Codex hooks from $CODEX_HOOKS_FILE..."

python3 - << EOF
import json, os, sys

hooks_path = "$CODEX_HOOKS_FILE"
install_dir = "$INSTALL_DIR"

if not os.path.exists(hooks_path):
    print("  hooks.json not found, skipping")
    sys.exit(0)

try:
    cfg = json.load(open(hooks_path))
except Exception as e:
    print(f"  error reading hooks.json: {e}")
    sys.exit(0)

changed = False
for event, entries in cfg.get("hooks", {}).items():
    for entry in entries:
        original = list(entry.get("hooks", []))
        entry["hooks"] = [
            h for h in original
            if install_dir not in h.get("command", "")
        ]
        if len(entry["hooks"]) != len(original):
            changed = True

if changed:
    tmp_path = hooks_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, hooks_path)
    print("  Removed tab-chroma Codex hook entries.")
else:
    print("  No tab-chroma Codex hooks found.")
EOF

# ─── 3. Reset tab color and clear badge ───────────────────────────────────────

if [ "$TERM_PROGRAM" = "iTerm.app" ]; then
  if { printf '\033]6;1;bg;*;default\a'
       printf '\033]1337;SetBadgeFormat=\a'; } 2>/dev/null > /dev/tty; then
    echo "Tab color reset and badge cleared."
  fi
fi

# ─── 4. Remove completions ────────────────────────────────────────────────────

echo "Removing completions..."

BASH_COMPLETION="$HOME/.bash_completion.d/tab-chroma"
if [ -f "$BASH_COMPLETION" ]; then
  rm -f "$BASH_COMPLETION"
  echo "  removed $BASH_COMPLETION"
fi

FISH_COMPLETION="$HOME/.config/fish/completions/tab-chroma.fish"
if [ -f "$FISH_COMPLETION" ]; then
  rm -f "$FISH_COMPLETION"
  echo "  removed $FISH_COMPLETION"
fi

# ─── 5. Note about alias ──────────────────────────────────────────────────────

echo ""
echo "Note: if you added 'alias tab-chroma=...' to .zshrc/.bashrc, remove it manually."

# ─── 6. Remove install directory ──────────────────────────────────────────────

echo ""
echo "Removing $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
echo "Done. tab-chroma has been uninstalled."
