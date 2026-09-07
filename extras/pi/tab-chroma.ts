/**
 * tab-chroma — pi extension
 *
 * Drives the same tab-chroma hook pipeline Claude Code and Codex use, but from
 * inside pi. pi has no static hooks file; it loads extensions from
 * `~/.pi/agent/extensions/`. This extension maps pi lifecycle events onto the
 * hook JSON that tab-chroma.sh reads on stdin, so the same iTerm2 tab colors,
 * badges, titles, and session-registry rows that agents get for Claude/Codex
 * light up for pi sessions too.
 *
 * Install: copy this file to `~/.pi/agent/extensions/tab-chroma.ts` (or point
 * the `extensions` setting in `~/.pi/agent/settings.json` at this path). pi
 * auto-loads `.ts` extensions next to its runtime; no build step is needed.
 *
 * The hook command is resolved the same way the Claude/Codex hooks resolve it:
 *   1. `TAB_CHROMA_HOOK_CMD` (set by the Homebrew wrapper)
 *   2. `TAB_CHROMA_SHARE/tab-chroma.sh`
 *   3. `~/.claude/hooks/tab-chroma/tab-chroma.sh` (local/curl install)
 *   4. `tab-chroma` on PATH (Homebrew wrapper)
 *
 * Every invocation sets `TAB_CHROMA_AGENT=pi` so sessions register under the
 * "pi" agent (letter `P` in the menu-bar lights).
 *
 * Event mapping:
 *   pi event              → tab-chroma hook event
 *   session_start         → SessionStart    (reset)
 *   session_shutdown      → SessionEnd      (reset + clear session pin)
 *   agent_start           → UserPromptSubmit (working)
 *   tool_execution_start  → PreToolUse      (working)
 *   tool_execution_end    → PostToolUse     (working)
 *   agent_settled         → Stop            (done)
 *   ui_prompt_start       → Notification    (attention)
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const AGENT = "pi";

function resolveHookCmd(): string | null {
  const env = process.env;

  // 1. The Homebrew wrapper exports TAB_CHROMA_HOOK_CMD at the bin/tab-chroma
  //    wrapper so hooks survive upgrades. Prefer it exactly like the hooks do.
  if (env.TAB_CHROMA_HOOK_CMD) return env.TAB_CHROMA_HOOK_CMD;

  // 2. TAB_CHROMA_SHARE points at the share dir (Homebrew or install.sh).
  if (env.TAB_CHROMA_SHARE) {
    const p = join(env.TAB_CHROMA_SHARE, "tab-chroma.sh");
    if (existsSync(p)) return p;
  }

  // 3. Local / curl install copies the script here.
  const local = join(homedir(), ".claude/hooks/tab-chroma/tab-chroma.sh");
  if (existsSync(local)) return local;

  // 4. Fall back to the wrapper on PATH (Homebrew `tab-chroma`).
  return "tab-chroma";
}

interface Ctx {
  cwd?: string;
  sessionManager?: {
    getSessionId?: () => string | undefined;
    getSessionFile?: () => string | undefined;
  };
}

function sessionId(ctx: Ctx | undefined): string {
  const fromCtx = ctx?.sessionManager?.getSessionId?.();
  if (fromCtx) return fromCtx;
  // pi exports PI_SESSION_ID to the bash tool env; extensions don't always see
  // it, but check anyway as a last resort.
  if (process.env.PI_SESSION_ID) return process.env.PI_SESSION_ID;
  return "";
}

// Fire-and-forget: feed one hook event's JSON to tab-chroma.sh on stdin. The
// script reads stdin in hook mode (no args, stdin not a TTY) and applies escape
// sequences to its resolved /dev/tty (pi's iTerm2 terminal). We never block the
// event loop on the hook — tab-chroma is debounced and write-only, so a dropped
// or slow invocation is preferable to stalling pi's lifecycle.
function emit(cmd: string, event: string, ctx: Ctx | undefined): void {
  const payload = JSON.stringify({
    hook_event_name: event,
    cwd: ctx?.cwd ?? process.cwd(),
    session_id: sessionId(ctx),
  });

  const child = spawn(cmd, [], {
    stdio: ["pipe", "ignore", "ignore"],
    env: { ...process.env, TAB_CHROMA_AGENT: AGENT },
    windowsHide: true,
  });

  child.on("error", () => {
    // Swallow: hook failures must never break pi.
  });

  child.stdin.on("error", () => {});
  child.stdin.end(payload);
}

export default function (pi: ExtensionAPI): void {
  const cmd = resolveHookCmd();
  if (!cmd) return;

  let root = false;

  pi.on("session_start", (_event, ctx) => {
    // Only drive visuals for sessions with a real UI. In --mode json / -p
    // (hasUI false) there is no iTerm2 tab to colorate and spawning the hook
    // per event is pure overhead, so stay inert. Extension reloads
    // (reason "reload") re-fire session_start; that's fine — SessionStart maps
    // to a tab reset, which is idempotent.
    if (!ctx.hasUI) return;
    root = true;
    emit(cmd, "SessionStart", ctx as Ctx);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    if (!root) return;
    // Pass ctx so SessionEnd carries the real session_id; tab-chroma uses it
    // to pop this session's theme pin (session_themes.pop(session_id)), which
    // is gated on `if session_id` — an empty id would leak the pin.
    emit(cmd, "SessionEnd", ctx as Ctx);
  });

  pi.on("agent_start", (_event, ctx) => {
    if (!root) return;
    emit(cmd, "UserPromptSubmit", ctx as Ctx);
  });

  pi.on("agent_settled", (_event, ctx) => {
    if (!root) return;
    emit(cmd, "Stop", ctx as Ctx);
  });

  pi.on("tool_execution_start", (_event, ctx) => {
    if (!root) return;
    emit(cmd, "PreToolUse", ctx as Ctx);
  });

  pi.on("tool_execution_end", (_event, ctx) => {
    if (!root) return;
    emit(cmd, "PostToolUse", ctx as Ctx);
  });

  pi.on("ui_prompt_start", (_event, ctx) => {
    if (!root) return;
    // A blocking prompt (confirm/input/editor/custom) means pi is waiting on
    // the user — that's the attention cue. Stop covers the "done" case.
    emit(cmd, "Notification", ctx as Ctx);
  });
}
