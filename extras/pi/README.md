# tab-chroma — pi extension

pi ([pi.dev](https://pi.dev)) does not use a static hooks file the way Claude
Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) do. Instead
it loads **extensions** from `~/.pi/agent/extensions/`. This directory holds a
single `tab-chroma.ts` extension that maps pi lifecycle events onto the same
hook JSON the Claude/Codex hooks emit, so pi sessions get the same iTerm2 tab
colors, badges, titles, and menu-bar lights.

## Event mapping

| pi event              | tab-chroma hook | state            |
|----------------------|-----------------|------------------|
| `session_start`      | `SessionStart`  | reset            |
| `session_shutdown`   | `SessionEnd`    | reset + clear pin |
| `agent_start`        | `UserPromptSubmit` | working       |
| `tool_execution_start` | `PreToolUse`  | working          |
| `tool_execution_end` | `PostToolUse`   | working          |
| `agent_settled`      | `Stop`          | done             |
| `ui_prompt_start`    | `Notification`  | attention        |

Every invocation sets `TAB_CHROMA_AGENT=pi`, so sessions register under the
`pi` agent and show with the letter `P` in the menu-bar lights.

## Install

Copy the extension into pi's global extensions directory:

```bash
mkdir -p ~/.pi/agent/extensions
cp extras/pi/tab-chroma.ts ~/.pi/agent/extensions/tab-chroma.ts
```

Or point pi at this path with the `extensions` setting in
`~/.pi/agent/settings.json` (path relative to `~/.pi/agent`, or absolute):

```json
{
  "extensions": ["path/to/tab-chroma.ts"]
}
```

Restart pi (or run `/reload`) to load it. The hook command is resolved the
same way the Claude/Codex hooks resolve it (`TAB_CHROMA_HOOK_CMD` →
`TAB_CHROMA_SHARE/tab-chroma.sh` → `~/.claude/hooks/tab-chroma/tab-chroma.sh`
→ `tab-chroma` on PATH), so as long as one of those is installed, pi will
light up the current iTerm2 tab.
