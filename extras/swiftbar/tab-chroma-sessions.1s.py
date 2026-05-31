#!/usr/bin/env python3
# <xbar.title>TabChroma Session Lights</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>TabChroma</xbar.author>
# <xbar.desc>One status light per active Claude Code / Codex session, read from the TabChroma shared registry.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.hideAbout>false</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>false</swiftbar.hideDisablePlugin>
#
# TabChroma Phase 2 menu-bar reader (SwiftBar / xbar).
#
# Renders one colored indicator per active agent session recorded in the shared
# TabChroma session registry (Phase 1), e.g.  C🔵 C🟢 X🔴  for two Claude and
# one Codex session. The dropdown lists every session with full detail.
#
# Install: see extras/swiftbar/README.md. This script is READ-ONLY against the
# registry — it never writes, so it cannot race the hook writers.
#
# Environment overrides:
#   TAB_CHROMA_REGISTRY_DB   path to sessions.sqlite3 (default: Application Support)
#   TAB_CHROMA_LIGHTS_COLLAPSE  collapse threshold (default 8; 0 disables collapse)
#   TAB_CHROMA_BIN           path to tab-chroma.sh for focus/prune/clear actions

import os
import sqlite3
import sys
import time

DEFAULT_DB = os.path.expanduser("~/Library/Application Support/TabChroma/sessions.sqlite3")
DB_PATH = os.environ.get("TAB_CHROMA_REGISTRY_DB") or DEFAULT_DB

try:
    COLLAPSE_THRESHOLD = int(os.environ.get("TAB_CHROMA_LIGHTS_COLLAPSE", "8"))
except ValueError:
    COLLAPSE_THRESHOLD = 8

# When enabled, prefix each menu-bar circle with the agent letter (C=Claude,
# X=Codex), e.g. "C🔵 X🟢" instead of "🔵 🟢". Off by default — just circles.
SHOW_AGENT_PREFIX = os.environ.get("TAB_CHROMA_LIGHTS_AGENT_PREFIX", "").strip().lower() in (
    "1", "true", "yes", "on",
)

# State -> menu-bar emoji. Matches TabChroma's semantic colors:
# working=blue, done=green, attention=orange, permission=red. The lifecycle-only
# states get neutral glyphs: starting=white, ended (afterglow)=black.
STATE_EMOJI = {
    "working": "🔵",
    "done": "🟢",
    "attention": "🟠",
    "permission": "🔴",
    "starting": "⚪",
    "ended": "⚫",
}
# Sort weight so the most "urgent" lights cluster left within an agent group.
STATE_ORDER = {
    "permission": 0,
    "attention": 1,
    "working": 2,
    "done": 3,
    "starting": 4,
    "ended": 5,
}
# Single-letter agent prefix shown next to each light.
AGENT_PREFIX = {"claude": "C", "codex": "X"}
# Keep agents in a stable order; unknown agents sort after the known ones.
AGENT_ORDER = {"claude": 0, "codex": 1}


def sanitize(text):
    """Strip characters that would corrupt a SwiftBar/xbar menu line.

    A literal '|' separates a line's text from its parameters, and newlines
    would split one row into several, so neutralize both in dynamic values
    (labels, paths, session ids) that originate from arbitrary projects.
    """
    return str(text).replace("|", "¦").replace("\n", " ").replace("\r", " ")


def shell_quote(text):
    """Single-quote a value for SwiftBar/xbar bash/param fields."""
    return "'" + str(text).replace("'", "'\\''") + "'"


def agent_prefix(agent):
    return AGENT_PREFIX.get(agent, (agent[:1].upper() or "?"))


def emoji(state):
    return STATE_EMOJI.get(state, "⚪")


def fmt_age(seconds):
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h"


def hex_color(r, g, b):
    if r is None or g is None or b is None:
        return None
    try:
        return "#{:02X}{:02X}{:02X}".format(int(r) & 255, int(g) & 255, int(b) & 255)
    except (TypeError, ValueError):
        return None


def find_tab_chroma_bin():
    candidates = [
        os.environ.get("TAB_CHROMA_BIN"),
        os.path.expanduser("~/.claude/hooks/tab-chroma/tab-chroma.sh"),
    ]
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    # Fall back to PATH lookup.
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, "tab-chroma")
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def read_sessions():
    """Return active (unexpired) session rows, or None if the DB is unavailable."""
    if not os.path.exists(DB_PATH):
        return []
    now = int(time.time())
    try:
        # Read-only URI connection: never create or lock the DB for writers.
        con = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=1.0)
    except sqlite3.Error:
        return None
    try:
        rows = con.execute(
            "SELECT session_key, agent, state, label, cwd, agent_session_id, "
            "       color_r, color_g, color_b, updated_at "
            "FROM sessions "
            "WHERE expires_at IS NULL OR expires_at >= ? "
            "ORDER BY updated_at DESC",
            (now,),
        ).fetchall()
    except sqlite3.OperationalError as e:
        # "no such table" means the registry exists but no hook has written yet
        # — treat as idle. Other operational errors (locked, I/O) are unreadable.
        if "no such table" in str(e).lower():
            return []
        return None
    except sqlite3.DatabaseError:
        # Corrupt / truncated / non-SQLite file → unreadable, not idle.
        # (DatabaseError is the parent of OperationalError, so this clause must
        # come second; "file is not a database" raises DatabaseError directly.)
        return None
    finally:
        con.close()
    return rows


def sort_key(row):
    agent, state, updated = row[1], row[2], row[9] or 0
    return (AGENT_ORDER.get(agent, 99), agent, STATE_ORDER.get(state, 99), -updated)


def render_menu_bar(rows):
    """Build the single menu-bar line (before the first '---').

    The menu bar shows one colored circle per session (most urgent first); the
    agent (Claude/Codex) is not encoded here — it is named in the dropdown.
    """
    if not rows:
        # Idle: keep a subtle, present indicator so the item stays clickable.
        return "○ | color=#888888"

    collapsed = bool(COLLAPSE_THRESHOLD) and len(rows) > COLLAPSE_THRESHOLD

    if SHOW_AGENT_PREFIX:
        # Agent-prefixed: group by agent, then severity, then recency.
        ordered = sorted(rows, key=sort_key)
        if collapsed:
            # One ×count per (agent, state) run.
            groups = []  # [agent, state, count]
            for agent, state in ((r[1], r[2]) for r in ordered):
                if groups and groups[-1][0] == agent and groups[-1][1] == state:
                    groups[-1][2] += 1
                else:
                    groups.append([agent, state, 1])
            tokens = [f"{agent_prefix(a)}{emoji(s)}×{n}" for a, s, n in groups]
        else:
            tokens = [f"{agent_prefix(r[1])}{emoji(r[2])}" for r in ordered]
    else:
        # Circles only: most-urgent state first, then most-recently-updated.
        ordered = sorted(rows, key=lambda r: (STATE_ORDER.get(r[2], 99), -(r[9] or 0)))
        if collapsed:
            counts = {}
            for r in ordered:
                counts[r[2]] = counts.get(r[2], 0) + 1
            states = sorted(counts, key=lambda s: STATE_ORDER.get(s, 99))
            tokens = [f"{emoji(s)}×{counts[s]}" for s in states]
        else:
            tokens = [emoji(r[2]) for r in ordered]
    return " ".join(tokens)


def render_dropdown(rows):
    lines = ["---"]
    now = int(time.time())
    bin_path = find_tab_chroma_bin()

    if rows:
        collapsed = bool(COLLAPSE_THRESHOLD) and len(rows) > COLLAPSE_THRESHOLD
        header = f"{len(rows)} active session{'s' if len(rows) != 1 else ''}"
        if collapsed:
            header += " (menu bar collapsed)"
        lines.append(f"{header} | size=11 color=#888888")
        for r in sorted(rows, key=sort_key):
            key, agent, state, label, cwd, sid, cr, cg, cb, updated = r
            label = sanitize(label or "(no label)")
            age = fmt_age(now - (updated or now))
            row_text = f"{agent_prefix(agent)}{emoji(state)}  {label} — {state} ({age})"
            color = hex_color(cr, cg, cb)
            params = ["font=Menlo", "size=12"]
            if color:
                params.append(f"color={color}")
            if bin_path:
                params.extend([
                    f"bash={shell_quote(bin_path)}",
                    "param1=sessions",
                    "param2=focus",
                    f"param3={shell_quote(key)}",
                    "terminal=false",
                    "refresh=true",
                ])
            lines.append(f"{row_text} | " + " ".join(params))
            # Detail submenu rows (indented with '--'). Keep these passive so a
            # user can copy/inspect without accidentally focusing.
            if cwd:
                lines.append(f"-- {sanitize(cwd)} | font=Menlo size=11 color=#888888")
            lines.append(f"-- {sanitize(key)} | font=Menlo size=11 color=#888888")
            lines.append(f"-- {sanitize(agent)}:{sanitize(sid or '(no id)')} | font=Menlo size=11 color=#888888")
    else:
        lines.append("No active sessions | color=#888888")

    # Actions footer.
    lines.append("---")
    lines.append("Refresh | refresh=true")
    if bin_path:
        qbin = shell_quote(bin_path)
        lines.append(
            f"Prune expired | bash={qbin} param1=sessions param2=prune "
            "terminal=false refresh=true"
        )
        lines.append(
            f"Clear all | bash={qbin} param1=sessions param2=clear "
            "terminal=false refresh=true"
        )
    reg_dir = os.path.dirname(DB_PATH)
    if reg_dir:
        lines.append(
            f"Open registry folder | bash=/usr/bin/open param1={shell_quote(reg_dir)} terminal=false"
        )
    lines.append(f"Registry: {sanitize(DB_PATH)} | size=10 color=#888888")
    return lines

def main():
    rows = read_sessions()
    if rows is None:
        # DB exists but could not be read (locked/corrupt) — degrade gracefully.
        print("⚠️ | color=#CC8800")
        print("---")
        print("TabChroma registry unreadable | color=#888888")
        print(f"Registry: {DB_PATH} | size=10 color=#888888")
        print("Refresh | refresh=true")
        return
    print(render_menu_bar(rows))
    for line in render_dropdown(rows):
        print(line)


if __name__ == "__main__":
    main()
