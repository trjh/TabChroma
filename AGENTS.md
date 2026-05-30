# AGENTS.md

This file gives OpenAI Codex guidance for working in this repository.

## Project overview

TabChroma is a small Bash + Python 3 terminal feedback plugin for agent CLIs. It changes iTerm2 tab color, badge, and title in response to lifecycle hook JSON from Claude Code and OpenAI Codex.

There is no package manager, dependency install, or build step. Keep changes minimal and avoid adding runtime dependencies.

## Important files

- `tab-chroma.sh` — main CLI and hook handler.
- `install.sh` / `uninstall.sh` — installer entry points.
- `themes/*/theme.json` — bundled color themes.
- `commands/*.md` — Claude slash-command docs.
- `completions/` — shell completions.
- `Formula/tab-chroma.rb` — Homebrew formula.

## Validation

Run these before committing:

```bash
bash -n tab-chroma.sh install.sh uninstall.sh
python3 -m json.tool themes/default/theme.json >/dev/null
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
