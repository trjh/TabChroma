# AGENTS.md

This file gives OpenAI Codex guidance for working in this repository.

## Project overview

TabChroma is a small Bash + Python 3 terminal feedback plugin for agent CLIs. It changes iTerm2 tab color, badge, and title in response to lifecycle hook JSON from Claude Code and OpenAI Codex.

It also keeps a shared SQLite **session registry** (`~/Library/Application Support/TabChroma/sessions.sqlite3`) and a **menu-bar "lights" UI** (one status light per active session; click to focus its iTerm2 pane, ordered to match the tab layout). CLI: `tab-chroma sessions <list|focus|order|prune|clear|path>`.

The core plugin has no package manager, dependency install, or build step. The one exception is the native menu-bar app in `native/`, a single Swift file built with `swiftc` (macOS SDK only). Keep changes minimal and avoid adding runtime dependencies.

## Important files

- `tab-chroma.sh` — main CLI and hook handler (incl. the `sessions` registry writer/CLI).
- `install.sh` / `uninstall.sh` — installer entry points.
- `themes/*/theme.json` — bundled color themes.
- `commands/*.md` — Claude slash-command docs.
- `completions/` — shell completions.
- `Formula/tab-chroma.rb` — Homebrew formula.
- `native/` — native macOS menu-bar app ("TabChroma Lights"); the primary session-lights UI.
- `extras/swiftbar/` — legacy SwiftBar/xbar session-lights plugin.
- `docs/design/session-registry-lights.md` — session registry + lights design and roadmap.

## Validation

Run these before committing:

```bash
/bin/bash -n tab-chroma.sh install.sh uninstall.sh   # use /bin/bash (3.2), not bash 5
python3 -m json.tool themes/default/theme.json >/dev/null
/bin/bash extras/tests/unit.sh                        # bash + Python unit checks
cd native && make test                                # build + non-GUI self-test (if touching native/)
```

For hook behavior, simulate events without needing iTerm2:

```bash
TAB_CHROMA_DATA="$(mktemp -d)" TAB_CHROMA_SHARE="$PWD" TERM_PROGRAM=iTerm.app \
  bash tab-chroma.sh <<'JSON'
{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/demo","session_id":"test"}
JSON
```

Visual commands such as `tab-chroma test working` must be run from an actual iTerm2 terminal to see colors/badges.

## Style notes

- Keep `tab-chroma.sh` POSIX-ish Bash; Bash-specific syntax is acceptable because the shebang is Bash.
- Keep hook stdout quiet. Hook runners consume stdout, so visual escape sequences must continue writing to the resolved `$TTY_DEVICE` instead of stdout.
- Quote or `shlex.quote` any values derived from hook JSON before feeding them into shell `eval`.
- Avoid adding dependencies beyond Bash, Python 3 standard library, and macOS/iTerm2 behavior already used by the project.
