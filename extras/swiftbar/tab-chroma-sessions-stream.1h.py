#!/usr/bin/env python3
# <xbar.title>TabChroma Session Lights (streaming)</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>TabChroma</xbar.author>
# <xbar.desc>One status light per active Claude Code / Codex session. Streaming variant: a resident process watches the registry and pushes updates on change.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.type>streamable</swiftbar.type>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#
# Streaming SwiftBar reader for the TabChroma session registry.
#
# Why this exists
# ---------------
# The poll reader `tab-chroma-sessions.1s.py` re-spawns python3 once per second
# just to open SQLite, run one SELECT, and print — up to ~1s of latency before a
# state change shows, plus an interpreter cold-start 86,400x/day. As a SwiftBar
# **streamable** plugin this script runs ONCE and stays resident: it watches the
# registry file's mtime and re-renders only when the registry actually changes,
# so lights flip ~immediately with near-zero idle cost.
#
# Streamable protocol (confirmed against SwiftBar docs)
# -----------------------------------------------------
# Marked streamable via `<swiftbar.type>streamable</swiftbar.type>`. The plugin
# emits a full menu block, then a line containing only `~~~`; SwiftBar resets the
# menu item on each `~~~`. The process runs until SwiftBar quits or it fails. We
# must flush after every block (python buffers stdout when it is not a tty, so
# without a flush SwiftBar would never see the output). The `.1h.py` interval in
# the filename is ignored for streamable plugins (it would only bound an
# auto-restart); the streaming loop does the real work.
#
# Single source of truth
# ----------------------
# All rendering is REUSED from the poll reader in this same folder: this script
# imports it as a module and calls its `render_lines()`. It owns only the
# watch/emit loop. We import the SIBLING poll plugin (found by glob, so a renamed
# interval like `.2s.py` still resolves) rather than a separate helper module,
# because SwiftBar "tries to import every file in the plugin folder as a plugin"
# (including nested folders) — a standalone library file would surface as a stray
# menu item, so there is nowhere safe to put one.
#
# Install / choose ONE
# --------------------
# The poll reader and this streaming reader are alternatives, not both-at-once:
#   - SwiftBar with streamable support  -> use this one.
#   - xbar, or older SwiftBar           -> use the poll reader.
# Copy BOTH files into the Plugins folder (this one needs the poll file present
# to import its renderer), but DISABLE the one you are not using in SwiftBar's
# plugin list so you get a single menu-bar item. See extras/swiftbar/README.md.

import glob
import importlib.util
import os
import signal
import sys
import time

POLL_INTERVAL = float(os.environ.get("TAB_CHROMA_STREAM_POLL", "0.25"))  # mtime-check cadence (s)
HEARTBEAT = float(os.environ.get("TAB_CHROMA_STREAM_HEARTBEAT", "5"))    # force a redraw at least this often (s)
SEPARATOR = "~~~"

HERE = os.path.dirname(os.path.abspath(__file__))


def _find_reader_path():
    """Locate the sibling poll plugin (the renderer we reuse).

    Matches `tab-chroma-sessions.<interval>.py` — the leading `.` after
    `sessions` means this glob does NOT match our own `...-sessions-stream...`
    filename, and it tolerates a renamed interval (`.1s.py`, `.2s.py`, ...).
    """
    for path in sorted(glob.glob(os.path.join(HERE, "tab-chroma-sessions.*.py"))):
        if os.path.abspath(path) != os.path.abspath(__file__):
            return path
    return None


def load_reader():
    path = _find_reader_path()
    if path is None:
        raise ImportError(
            f"poll reader 'tab-chroma-sessions.*.py' not found next to {__file__}; "
            "copy it into the same SwiftBar Plugins folder")
    spec = importlib.util.spec_from_file_location("tc_reader", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load reader module from {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # runs top-level defs only; main() is __main__-guarded
    return mod


def registry_signature(db_path):
    """Cheap change token: max mtime across the SQLite file and its WAL/SHM.

    In WAL mode a commit often lands in `-wal` while the main file's mtime lags,
    so we must watch all three. Returns 0.0 when nothing exists yet (idle /
    pre-first-write); that still differs from a real mtime, so the first real
    write triggers a redraw.
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


def emit(lines):
    """Write one full menu block, flush, and emit the streamable separator."""
    sys.stdout.write("\n".join(lines))
    sys.stdout.write("\n" + SEPARATOR + "\n")
    sys.stdout.flush()


def _install_signal_handlers():
    # SwiftBar terminates the process when it quits or the plugin is disabled.
    # Exit cleanly (no traceback) on SIGTERM/SIGINT.
    def _bye(_signum, _frame):
        sys.exit(0)
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, _bye)
        except (ValueError, OSError):
            pass


def main():
    _install_signal_handlers()
    try:
        reader = load_reader()
    except Exception as e:
        # Without the renderer we cannot draw; surface it once and idle so
        # SwiftBar shows a clickable error instead of hot-respawning us.
        emit([
            "⚠️ | color=#CC0000",
            "---",
            f"streaming reader: {e} | color=#888888",
            "Refresh | refresh=true",
        ])
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
                emit(reader.render_lines())
            except Exception as e:
                # Never let one bad cycle kill the resident loop; the next change
                # or heartbeat retries.
                emit([
                    "⚠️ | color=#CC8800",
                    "---",
                    f"streaming cycle error: {e} | color=#888888",
                ])
            last_sig = sig
            last_emit = now
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
