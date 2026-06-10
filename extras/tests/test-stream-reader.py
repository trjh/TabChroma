#!/usr/bin/env python3
"""Contract + render tests for the streaming SwiftBar reader.

The streaming reader (`tab-chroma-sessions-stream.1h.py`) owns ONLY the
watch/emit loop — it delegates all rendering to the sibling poll reader
(`tab-chroma-sessions.1s.py`), which it loads at runtime via `load_reader()`
and then drives through two attributes: `reader.DB_PATH` and
`reader.render_lines()`. That delegation is an implicit contract: if the poll
reader ever renamed or dropped either name, nothing would fail at import — the
break would surface only at runtime as a SwiftBar "streaming cycle error".

This test pins that contract and exercises the shared renderer against a
throwaway registry, so editing one reader without the other (or renaming the
shared API) fails here instead of silently in the menu bar. Run from anywhere:

    python3 extras/tests/test-stream-reader.py     # exit 0 = pass, 1 = fail

It never touches the real registry: TAB_CHROMA_REGISTRY_DB is pointed at a temp
file for every case (the poll reader binds DB_PATH from that env var at import,
and load_reader() re-imports it fresh on each call).
"""
import importlib.util
import os
import sqlite3
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFTBAR = os.path.normpath(os.path.join(HERE, "..", "swiftbar"))
STREAM = os.path.join(SWIFTBAR, "tab-chroma-sessions-stream.1h.py")

GRN = "\033[32m" if sys.stdout.isatty() else ""
RED = "\033[31m" if sys.stdout.isatty() else ""
OFF = "\033[0m" if sys.stdout.isatty() else ""

_passed = 0
_failed = 0


def check(name, cond):
    global _passed, _failed
    if cond:
        _passed += 1
        print(f"{GRN}PASS{OFF} {name}")
    else:
        _failed += 1
        print(f"{RED}FAIL{OFF} {name}")


def load_module(path, name):
    # dont_write_bytecode so we never leave a __pycache__ in the plugin folder
    # (SwiftBar would render a stray file there as a bogus menu item).
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # top-level defs only; main() is __main__-guarded
    return mod


SCHEMA = """
CREATE TABLE sessions (
  session_key TEXT PRIMARY KEY, agent TEXT, state TEXT, label TEXT, cwd TEXT,
  agent_session_id TEXT, color_r INTEGER, color_g INTEGER, color_b INTEGER,
  updated_at INTEGER, expires_at INTEGER
);
"""


def write_fixture(db_path, rows):
    con = sqlite3.connect(db_path)
    con.executescript(SCHEMA)
    con.executemany(
        "INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)
    con.commit()
    con.close()


def session_row(key, agent, state, age=0):
    now = int(time.time())
    return (key, agent, state, key.title(), f"/tmp/{key}", f"{agent}-{key}",
            None, None, None, now - age, None)  # expires_at NULL = live


def main():
    stream = load_module(STREAM, "tc_stream")
    tmp = tempfile.mkdtemp(prefix="tc-stream-test.")
    db = os.path.join(tmp, "sessions.sqlite3")

    # ── _find_reader_path resolves the poll reader, never the stream file ──────
    found = stream._find_reader_path()
    base = os.path.basename(found or "")
    check("_find_reader_path finds the poll reader",
          found is not None
          and base.startswith("tab-chroma-sessions.")
          and "-stream" not in base
          and os.path.abspath(found) != os.path.abspath(STREAM))

    # ── load_reader() satisfies the contract the stream loop depends on ────────
    os.environ["TAB_CHROMA_REGISTRY_DB"] = db
    os.environ.pop("TAB_CHROMA_LIGHTS_COLLAPSE", None)
    os.environ.pop("TAB_CHROMA_LIGHTS_AGENT_PREFIX", None)
    reader = stream.load_reader()
    check("load_reader exposes DB_PATH (str) honoring the env override",
          isinstance(getattr(reader, "DB_PATH", None), str) and reader.DB_PATH == db)
    check("load_reader exposes a callable render_lines()",
          callable(getattr(reader, "render_lines", None)))

    # ── render_lines: idle (no DB file yet) ────────────────────────────────────
    idle = reader.render_lines()
    check("render_lines idle returns a non-empty list of str",
          isinstance(idle, list) and idle and all(isinstance(x, str) for x in idle))
    check("render_lines idle menu-bar line is the dim circle",
          idle[0] == "○ | color=#888888")
    check("render_lines idle dropdown shows 'No active sessions' + Refresh",
          any("No active sessions" in x for x in idle)
          and any(x.startswith("Refresh | refresh=true") for x in idle))

    # ── render_lines: populated (3 live sessions) ──────────────────────────────
    write_fixture(db, [
        session_row("alpha", "claude", "working", age=5),
        session_row("bravo", "claude", "done", age=60),
        session_row("charlie", "codex", "permission", age=1),
    ])
    full = reader.render_lines()
    check("render_lines renders one menu-bar token per session (uncollapsed)",
          len(full[0].split(" ")) == 3)
    check("render_lines dropdown reports the active count",
          any("3 active sessions" in x for x in full))
    check("render_lines dropdown labels each session",
          all(any(name in x for x in full) for name in ("Alpha", "Bravo", "Charlie")))

    # ── render_lines: unreadable DB → graceful warning, not a crash ────────────
    bad = os.path.join(tmp, "corrupt.sqlite3")
    with open(bad, "w") as fh:
        fh.write("this is not a sqlite database")
    os.environ["TAB_CHROMA_REGISTRY_DB"] = bad
    reader_bad = stream.load_reader()
    warn = reader_bad.render_lines()
    check("render_lines on an unreadable DB degrades to a warning",
          any("unreadable" in x for x in warn) and warn[0].startswith("⚠️"))

    # ── registry_signature: change-detection across the DB + its WAL ───────────
    sig_dir = os.path.join(tmp, "sig")
    os.makedirs(sig_dir)
    sig_db = os.path.join(sig_dir, "sessions.sqlite3")
    check("registry_signature is 0.0 when nothing exists",
          stream.registry_signature(sig_db) == 0.0)
    open(sig_db, "w").close()
    os.utime(sig_db, (1000, 1000))
    check("registry_signature reflects the main file mtime",
          stream.registry_signature(sig_db) == 1000.0)
    open(sig_db + "-wal", "w").close()
    os.utime(sig_db + "-wal", (2000, 2000))
    check("registry_signature picks up a newer -wal mtime",
          stream.registry_signature(sig_db) == 2000.0)

    # ── emit: full block + streamable separator, written to stdout ─────────────
    import io
    buf, real = io.StringIO(), sys.stdout
    sys.stdout = buf
    try:
        stream.emit(["line-1", "line-2"])
    finally:
        sys.stdout = real
    check("emit writes the block then the ~~~ separator",
          buf.getvalue() == "line-1\nline-2\n~~~\n")

    # ── cleanup ────────────────────────────────────────────────────────────────
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)

    print(f"{_passed} passed, {_failed} failed")
    return 0 if _failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
