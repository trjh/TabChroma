#!/usr/bin/env python3
# <xbar.title>TabChroma Session Lights (streaming)</xbar.title>
# <xbar.version>v0.1-proto</xbar.version>
# <xbar.author>TabChroma</xbar.author>
# <xbar.desc>Streaming variant: one resident process watches the registry and pushes updates on change, instead of re-spawning python3 every second.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.type>streamable</swiftbar.type>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#
# PROTOTYPE — streamable SwiftBar reader for the TabChroma session registry.
#
# Why this exists
# ---------------
# The shipped reader `tab-chroma-sessions.1s.py` is a *poll + respawn* plugin:
# SwiftBar cold-starts a fresh python3 once per second just to open SQLite, run
# one SELECT, and print. That is the "a bit slow / heavy" feel — up to ~1s of
# latency before a state change shows, plus an interpreter spawn 86,400×/day.
#
# A SwiftBar **streamable** plugin runs ONCE and stays resident: this script
# holds nothing open against the DB (it still reads read-only per cycle) but it
# pays the python startup cost exactly once, and it goes event-driven — it
# watches the registry file's mtime and re-renders only when the registry
# actually changes, so lights flip ~immediately with near-zero idle cost. This
# captures most of what a native Swift menu-bar app would buy, with no build
# step and no new dependency — staying within the project's "pure bash + Python
# 3" ethos. See docs/design/session-registry-lights.md.
#
# Streamable protocol (VERIFY against your SwiftBar version)
# ---------------------------------------------------------
# A streamable plugin emits a full menu block, then a line containing only
# `~~~`, which tells SwiftBar "that block is complete, render it" — then it keeps
# the process alive and emits the next block whenever it likes. The separator
# token and exact semantics have varied across SwiftBar releases; if the menu
# shows literal `~~~` lines or never updates, your SwiftBar build wants a
# different token (or doesn't support streaming) — fall back to the shipped
# `tab-chroma-sessions.1s.py`. This is why the file is marked v0.1-proto.
#
# Single source of truth
# ----------------------
# All rendering (menu-bar line, dropdown, colors, collapse, sanitization,
# actions) is REUSED from the shipped `tab-chroma-sessions.1s.py` in this same
# folder via importlib — this file only owns the watch/emit loop, so the two can
# never drift in how a session is drawn.
#
# Install: copy BOTH this file and tab-chroma-sessions.1s.py into your SwiftBar
# Plugins folder (they must sit side by side so the import resolves), then enable
# only ONE of them in SwiftBar so you don't get two menu-bar items. The `.1h.py`
# interval is just a safety re-spawn cadence; the streaming loop does the real
# work between respawns.

import importlib.util
import os
import sys
import time

POLL_INTERVAL = float(os.environ.get("TAB_CHROMA_STREAM_POLL", "0.25"))  # mtime check cadence (s)
HEARTBEAT = float(os.environ.get("TAB_CHROMA_STREAM_HEARTBEAT", "5"))    # force a redraw at least this often (s)
SEPARATOR = "~~~"

HERE = os.path.dirname(os.path.abspath(__file__))
READER_PATH = os.path.join(HERE, "tab-chroma-sessions.1s.py")


def load_reader():
    """Import the shipped reader as a module so we reuse its render functions."""
    spec = importlib.util.spec_from_file_location("tc_reader", READER_PATH)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load reader module from {READER_PATH}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # runs top-level (defs + DB_PATH from env); main() is guarded
    return mod


def registry_signature(db_path):
    """A cheap change token: max mtime across the SQLite file and its WAL/SHM.

    In WAL mode a commit often lands in `-wal` while the main file's mtime
    lags, so we must watch all three. Returns 0.0 when nothing exists yet
    (idle / pre-first-write), which still differs from a real mtime so the
    first real write triggers a redraw.
    """
    newest = 0.0
    for suffix in ("", "-wal", "-shm"):
        try:
            m = os.stat(db_path + suffix).st_mtime
            if m > newest:
                newest = m
        except OSError:
            pass
    return newest


def emit(reader):
    """Render one full menu block (reusing the shipped reader) and flush + separate."""
    rows = reader.read_sessions()
    if rows is None:
        # Mirror the shipped reader's degraded state for an unreadable DB.
        out = ["⚠️ | color=#CC8800", "---",
               "TabChroma registry unreadable | color=#888888",
               f"Registry: {reader.DB_PATH} | size=10 color=#888888",
               "Refresh | refresh=true"]
    else:
        out = [reader.render_menu_bar(rows)] + reader.render_dropdown(rows)
    sys.stdout.write("\n".join(out))
    sys.stdout.write("\n" + SEPARATOR + "\n")
    sys.stdout.flush()


def main():
    try:
        reader = load_reader()
    except Exception as e:
        # Without the shipped reader we cannot render; surface it once and idle so
        # SwiftBar shows a clickable error rather than a blank/looping item.
        sys.stdout.write(f"⚠️ | color=#CC0000\n---\n"
                         f"stream proto: could not import reader: {e} | color=#888888\n"
                         f"Expected next to: {READER_PATH} | size=10 color=#888888\n"
                         f"{SEPARATOR}\n")
        sys.stdout.flush()
        # Block instead of busy-exiting so SwiftBar doesn't hot-respawn us.
        while True:
            time.sleep(3600)

    db_path = reader.DB_PATH
    last_sig = None
    last_emit = 0.0
    while True:
        sig = registry_signature(db_path)
        now = time.time()
        if sig != last_sig or (now - last_emit) >= HEARTBEAT:
            try:
                emit(reader)
            except Exception as e:
                # Never let one bad cycle kill the resident loop — degrade and
                # keep going; the next change or heartbeat retries.
                sys.stdout.write(f"⚠️ | color=#CC8800\n---\n"
                                 f"stream proto cycle error: {e} | color=#888888\n{SEPARATOR}\n")
                sys.stdout.flush()
            last_sig = sig
            last_emit = now
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
