#!/usr/bin/env bash
# inject-test-light.sh — add / change / remove a TEST light in the TabChroma
# registry, so you can watch the SwiftBar streaming plugin update live on your
# own schedule (no guessing when an injected light "should have" appeared).
#
#   ./inject-test-light.sh                 # add a blue 'working' test light
#   ./inject-test-light.sh done            # change it to green (run again to watch it flip)
#   ./inject-test-light.sh attention       # orange
#   ./inject-test-light.sh permission      # red
#   ./inject-test-light.sh off             # remove it
#
# The row is PID-less and expires in 5 min, so it self-cleans and the liveness
# sweep won't touch it. Override the DB with TAB_CHROMA_REGISTRY_DB.
set -u
DB="${TAB_CHROMA_REGISTRY_DB:-$HOME/Library/Application Support/TabChroma/sessions.sqlite3}"
arg="${1:-working}"
python3 - "$DB" "$arg" <<'PY'
import sqlite3, sys, time
db, arg = sys.argv[1], sys.argv[2]
now = int(time.time())
KEY = "claude:LIVE-STREAM-TEST"
if not __import__("os").path.exists(db):
    print(f"registry not found: {db}"); sys.exit(1)
con = sqlite3.connect(db, timeout=2); con.execute("PRAGMA busy_timeout=1000")
if arg in ("off", "remove", "clear", "delete"):
    n = con.execute("DELETE FROM sessions WHERE session_key=?", (KEY,)).rowcount
    con.commit(); print(f"removed test light ({n} row).")
else:
    colors = {"working": (0,100,200), "done": (0,160,0),
              "attention": (255,160,40), "permission": (220,0,0)}
    state = arg if arg in colors else "working"
    r, g, b = colors[state]
    con.execute("DELETE FROM sessions WHERE session_key=?", (KEY,))
    con.execute("""INSERT INTO sessions(session_key,agent,agent_session_id,state,label,cwd,
        updated_at,expires_at,session_pid,pid_start,color_r,color_g,color_b)
        VALUES(?,?,?,?,?,?,?,?,NULL,NULL,?,?,?)""",
        (KEY, "claude", KEY, state, f"LIVE-STREAM-TEST ({state})", "/tmp",
         now, now+300, r, g, b))
    con.commit()
    print(f"test light -> {state}. Look at the menu bar now. Remove with: inject-test-light.sh off")
PY
