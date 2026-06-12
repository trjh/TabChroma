// TabChroma Lights — a compact native macOS menu-bar app.
//
// One status light per active Claude Code / Codex session, read from the shared
// TabChroma SQLite registry. Event-driven (watches the registry, no polling
// respawn), no plugin host, no dependencies beyond the macOS SDK. Clicking a
// session reuses the existing `tab-chroma sessions focus <key>` CLI.
//
// Build & run (no Xcode project, no bundle needed):
//   swiftc -swift-version 5 -O main.swift -o tabchroma-lights -framework AppKit
//   ./tabchroma-lights
//
// Env overrides (same as the SwiftBar reader):
//   TAB_CHROMA_REGISTRY_DB        registry path (default: Application Support)
//   TAB_CHROMA_LIGHTS_COLLAPSE    collapse threshold (default 8; 0 disables)
//   TAB_CHROMA_LIGHTS_AGENT_PREFIX  prefix each light with C/X (default off)
//   TAB_CHROMA_BIN                path to tab-chroma.sh for focus/prune actions

import AppKit
import Darwin
import Foundation
import SQLite3

// ── Config ───────────────────────────────────────────────────────────────────
let environment = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser.path
let dbPath = environment["TAB_CHROMA_REGISTRY_DB"]
    ?? "\(home)/Library/Application Support/TabChroma/sessions.sqlite3"
let collapseThreshold = Int(environment["TAB_CHROMA_LIGHTS_COLLAPSE"] ?? "8") ?? 8
// Prefix each light with its agent letter (C=Claude, X=Codex). Off by default
// because it is redundant noise when every session is the same agent; turn it
// on for mixed Claude+Codex setups. Accepts 1/true/yes (case-insensitive).
let agentPrefix = ["1", "true", "yes"].contains(
    (environment["TAB_CHROMA_LIGHTS_AGENT_PREFIX"] ?? "").lowercased())

let stateEmoji: [String: String] = [
    "working": "🔵", "done": "🟢", "attention": "🟠",
    "permission": "🔴", "starting": "⚪", "ended": "⚫",
]
let stateRank: [String: Int] = [
    "permission": 0, "attention": 1, "working": 2, "done": 3, "starting": 4, "ended": 5,
]
let agentRank: [String: Int] = ["claude": 0, "codex": 1]
let agentLetter: [String: String] = ["claude": "C", "codex": "X"]

// Persisted (UserDefaults) toggle for the "Show tty & pid" dropdown item: append
// each session's pid + tty inline. Off by default to keep the menu short.
let showTtyPidKey = "ShowTtyPid"

func emoji(_ s: String) -> String { stateEmoji[s] ?? "⚪" }
func rank(_ s: String) -> Int { stateRank[s] ?? 99 }
func arank(_ a: String) -> Int { agentRank[a] ?? 99 }
func aletter(_ a: String) -> String { agentLetter[a] ?? "?" }

func fmtAge(_ secs: Int) -> String {
    let s = max(0, secs)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
}

struct Session {
    var key, agent, state, label: String
    var r, g, b: Int?
    var updated: Int
    // Detail fields (shown inline by the "Show tty & pid" toggle); default so
    // fixtures can omit them.
    var tty: String = ""
    var pid: Int? = nil
    // Positional rank (Phase 5) stamped by `sessions order`; nil when ordering
    // has not run or this row's tty is off-screen. Defaulted so fixtures omit it.
    var order: Int? = nil
}

// ── Registry read (read-only SQLite; mode=ro so it never locks the writers) ───
func readSessions() -> [Session] {
    guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
    var db: OpaquePointer?
    guard sqlite3_open_v2("file:\(dbPath)?mode=ro", &db,
                          SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return []
    }
    defer { sqlite3_close(db) }
    let cols = "session_key, agent, state, label, color_r, color_g, color_b, updated_at"
    let tail = " FROM sessions WHERE expires_at IS NULL OR expires_at >= ? ORDER BY updated_at DESC"
    var stmt: OpaquePointer?
    // Try richest column-set first and fall back one tier at a time, so a DB that
    // has tty/pid but not yet `display_order` still yields tty/pid (and a really
    // old DB still yields the base columns). A failed prepare on the base query
    // most commonly means the table does not exist yet (no hook has written) —
    // treat that as idle rather than an error.
    let variants: [(sel: String, detail: Bool, order: Bool)] = [
        (cols + ", tty_device, session_pid, display_order", true, true),
        (cols + ", tty_device, session_pid", true, false),
        (cols, false, false),
    ]
    var hasDetail = false
    var hasOrder = false
    var prepared = false
    for v in variants {
        if sqlite3_prepare_v2(db, "SELECT " + v.sel + tail, -1, &stmt, nil) == SQLITE_OK {
            hasDetail = v.detail
            hasOrder = v.order
            prepared = true
            break
        }
        sqlite3_finalize(stmt)
        stmt = nil
    }
    guard prepared else { return [] }
    defer { sqlite3_finalize(stmt) }
    let now = Int(Date().timeIntervalSince1970)
    sqlite3_bind_int64(stmt, 1, Int64(now))

    func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    func intOrNil(_ i: Int32) -> Int? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
    }

    var rows: [Session] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        rows.append(Session(
            key: text(0), agent: text(1), state: text(2), label: text(3),
            r: intOrNil(4), g: intOrNil(5), b: intOrNil(6), updated: intOrNil(7) ?? now,
            tty: hasDetail ? text(8) : "", pid: hasDetail ? intOrNil(9) : nil,
            order: hasOrder ? intOrNil(10) : nil))
    }
    return rows
}

// Positional display order (Phase 5) when EVERY shown session carries a
// display_order; otherwise the caller's severity/recency fallback. Requiring all
// rows to be stamped means a half-populated order never scrambles the line — it
// only takes effect once `sessions order` has ranked the whole visible set.
func orderedForDisplay(_ sessions: [Session], fallback: (Session, Session) -> Bool) -> [Session] {
    if !sessions.isEmpty && sessions.allSatisfy({ $0.order != nil }) {
        return sessions.sorted { $0.order! < $1.order! }
    }
    return sessions.sorted(by: fallback)
}

// Menu-bar string: one circle per session (most urgent first), collapsed to
// grouped counts past the threshold — matching the SwiftBar reader. With
// `prefix`, each light carries its agent letter (C🔵 / X🟢) and the collapsed
// form groups by (agent, state) instead of state alone.
func menuBarTitle(_ sessions: [Session], prefix: Bool = agentPrefix) -> String {
    if sessions.isEmpty { return "○" }
    if collapseThreshold > 0 && sessions.count > collapseThreshold {
        if prefix {
            var counts: [String: Int] = [:]   // key: "agent\tstate"
            for s in sessions { counts["\(s.agent)\t\(s.state)", default: 0] += 1 }
            return counts.keys
                .sorted {
                    let (a0, s0) = split($0), (a1, s1) = split($1)
                    return (arank(a0), rank(s0)) < (arank(a1), rank(s1))
                }
                .map { let (a, s) = split($0); return "\(aletter(a))\(emoji(s))×\(counts[$0]!)" }
                .joined(separator: " ")
        }
        var counts: [String: Int] = [:]
        for s in sessions { counts[s.state, default: 0] += 1 }
        return counts.keys.sorted { rank($0) < rank($1) }
            .map { "\(emoji($0))×\(counts[$0]!)" }
            .joined(separator: " ")
    }
    return orderedForDisplay(sessions) {
            (rank($0.state), -$0.updated) < (rank($1.state), -$1.updated)
        }
        .map { (prefix ? aletter($0.agent) : "") + emoji($0.state) }
        .joined(separator: " ")
}

// Split a "agent\tstate" group key back into its parts.
private func split(_ key: String) -> (String, String) {
    let parts = key.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    return (String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : "")
}

// ── tab-chroma CLI (reused for focus / prune) ─────────────────────────────────
func tabChromaBin() -> String? {
    var candidates: [String] = []
    if let b = environment["TAB_CHROMA_BIN"] { candidates.append(b) }
    candidates.append("\(home)/.claude/hooks/tab-chroma/tab-chroma.sh")
    for dir in (environment["PATH"] ?? "").split(separator: ":") {
        candidates.append("\(dir)/tab-chroma")
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func runTabChroma(_ args: [String]) {
    guard let bin = tabChromaBin() else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    try? p.run()
}

// ── Self-test ────────────────────────────────────────────────────────────────
func runSelfTests() -> Int32 {
    var passed = 0
    var failed = 0

    func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            passed += 1
            print("PASS \(name)")
        } else {
            failed += 1
            print("FAIL \(name)")
        }
    }

    func execSQL(_ db: OpaquePointer?, _ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if let err {
            sqlite3_free(err)
        }
        return ok
    }

    check("fmtAge clamps negative values", fmtAge(-7) == "0s")
    check("fmtAge renders seconds", fmtAge(59) == "59s")
    check("fmtAge renders minutes", fmtAge(3599) == "59m")
    check("fmtAge renders hours", fmtAge(7200) == "2h")
    check("emoji falls back for unknown states", emoji("mystery") == "⚪")
    check("rank falls back after known states", rank("mystery") == 99)
    check("menuBarTitle renders idle state", menuBarTitle([]) == "○")

    let sessions = [
        Session(key: "done-old", agent: "claude", state: "done", label: "Done", r: nil, g: nil, b: nil, updated: 300),
        Session(key: "permission", agent: "claude", state: "permission", label: "Permission", r: nil, g: nil, b: nil, updated: 100),
        Session(key: "working-new", agent: "codex", state: "working", label: "Working", r: nil, g: nil, b: nil, updated: 500),
    ]
    // Assertions depend on whether the ambient collapseThreshold collapses these
    // 3 sessions (the `make test` target sets it to 2; the default is 8).
    if collapseThreshold > 0 && sessions.count > collapseThreshold {
        check("menuBarTitle collapses by severity", menuBarTitle(sessions, prefix: false) == "🔴×1 🔵×1 🟢×1")
        // Prefixed collapse groups by (agent, state), ordered agent-then-severity.
        check("menuBarTitle collapses by agent+state", menuBarTitle(sessions, prefix: true) == "C🔴×1 C🟢×1 X🔵×1")
    } else {
        check("menuBarTitle sorts by severity", menuBarTitle(sessions, prefix: false) == "🔴 🔵 🟢")
        // Expanded keeps state-severity order; the codex 'working' sorts between the claude rows.
        check("menuBarTitle prefixes agent letters", menuBarTitle(sessions, prefix: true) == "C🔴 X🔵 C🟢")
    }

    // Phase 5 ordering: positional sort when every row is stamped; otherwise the
    // caller's fallback comparator. Fallback here is plain state severity.
    let ranked = [
        Session(key: "c", agent: "claude", state: "working", label: "", r: nil, g: nil, b: nil, updated: 10, order: 3),
        Session(key: "a", agent: "claude", state: "done", label: "", r: nil, g: nil, b: nil, updated: 10, order: 1),
        Session(key: "b", agent: "codex", state: "permission", label: "", r: nil, g: nil, b: nil, updated: 10, order: 2),
    ]
    check("orderedForDisplay sorts by display_order when all set",
          orderedForDisplay(ranked) { rank($0.state) < rank($1.state) }.map(\.key) == ["a", "b", "c"])
    var partlyRanked = ranked
    partlyRanked[0].order = nil   // one missing -> fall back to severity (perm<work<done)
    check("orderedForDisplay falls back when any display_order is nil",
          orderedForDisplay(partlyRanked) { rank($0.state) < rank($1.state) }.map(\.key) == ["b", "c", "a"])

    guard environment["TAB_CHROMA_REGISTRY_DB"] != nil else {
        print("FAIL self-test requires TAB_CHROMA_REGISTRY_DB")
        print("\(passed) passed, \(failed + 1) failed")
        return 1
    }

    _ = try? FileManager.default.removeItem(atPath: dbPath)
    let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent().path
    if !dir.isEmpty {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    var db: OpaquePointer?
    if sqlite3_open(dbPath, &db) == SQLITE_OK {
        let now = Int(Date().timeIntervalSince1970)
        // Full schema (incl. tty_device/session_pid/display_order) so readSessions
        // exercises its richest query tier, not just the base-column fallback.
        let created = execSQL(db, """
            CREATE TABLE sessions (
              session_key TEXT PRIMARY KEY,
              agent TEXT NOT NULL,
              state TEXT NOT NULL,
              label TEXT,
              color_r INTEGER, color_g INTEGER, color_b INTEGER,
              updated_at INTEGER NOT NULL,
              expires_at INTEGER,
              tty_device TEXT, session_pid INTEGER, display_order INTEGER
            );
            """)
        let inserted = execSQL(db, """
            INSERT INTO sessions VALUES
              ('live-new','codex','working','Live New',0,100,200,\(now),NULL,'/dev/ttys9',4242,2),
              ('live-old','claude','permission','Live Old',220,60,40,\(now - 30),\(now + 60),'/dev/ttys8',NULL,1),
              ('expired','claude','done','Expired',34,180,80,\(now - 10),\(now - 1),'/dev/ttys7',1,3);
            """)
        sqlite3_close(db)
        check("self-test creates registry fixture", created && inserted)

        let rows = readSessions()
        check("readSessions filters expired rows", rows.map(\.key).sorted() == ["live-new", "live-old"])
        check("readSessions keeps SQL recency order", rows.map(\.key) == ["live-new", "live-old"])
        check("readSessions reads RGB values", rows.first { $0.key == "live-old" }?.r == 220)
        check("readSessions reads tty/pid detail", rows.first { $0.key == "live-new" }?.tty == "/dev/ttys9"
              && rows.first { $0.key == "live-new" }?.pid == 4242)
        check("readSessions reads display_order", rows.first { $0.key == "live-old" }?.order == 1)
    } else {
        sqlite3_close(db)
        check("self-test opens registry fixture", false)
    }

    _ = try? FileManager.default.removeItem(atPath: dbPath)
    var blank: OpaquePointer?
    if sqlite3_open(dbPath, &blank) == SQLITE_OK {
        sqlite3_close(blank)
        check("readSessions treats missing table as idle", readSessions().isEmpty)
    } else {
        sqlite3_close(blank)
        check("readSessions treats missing table as idle", false)
    }

    print("\(passed) passed, \(failed) failed")
    return failed == 0 ? 0 : 1
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTests())
}

// ── App ───────────────────────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var lastSignature: Double = -1
    var timer: DispatchSourceTimer?
    // Phase 5 ordering trigger: re-rank lights to iTerm2 tab order on launch and
    // every `orderEveryTicks` ticks (0.5s each → ~4s). `orderInFlight` coalesces
    // so a slow AppleScript walk never stacks up behind the timer.
    var ticksSinceOrder = 0
    let orderEveryTicks = 8
    var orderInFlight = false

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.title = "○"
        menu.delegate = self            // dropdown rebuilt fresh on each open (ages current)
        statusItem.menu = menu
        updateTitle()
        maybeOrder()                    // rank to tab order immediately on launch
        startWatching()
    }

    // Re-render the menu-bar title only when the registry actually changes.
    // A 0.5s mtime-gated poll of the DB (+ its -wal/-shm): the stat() is
    // negligible and a SQLite read happens only on an actual change — none of
    // SwiftBar's per-tick python respawn cost.
    //
    // (An earlier revision pushed updates via FSEvents instead, but in-place
    // SQLite WAL writes did not reliably deliver events — FSEventStreamStart
    // would succeed yet never call back, leaving the menu frozen at its startup
    // snapshot. The simple timer is correct and cheap, so it is the mechanism.)
    func startWatching() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func registrySignature() -> Double {
        var newest = 0.0
        for suffix in ["", "-wal", "-shm"] {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath + suffix),
               let date = attrs[.modificationDate] as? Date {
                newest = max(newest, date.timeIntervalSince1970)
            }
        }
        return newest
    }

    func tick() {
        let sig = registrySignature()
        if sig != lastSignature {
            lastSignature = sig
            updateTitle()
        }
        ticksSinceOrder += 1
        if ticksSinceOrder >= orderEveryTicks {
            ticksSinceOrder = 0
            maybeOrder()
        }
    }

    // Fire `tab-chroma sessions order` in the background to re-rank lights to the
    // current iTerm2 tab layout. Skipped when idle (no sessions → no AppleScript
    // round-trip) and coalesced via `orderInFlight`. `order` writes only changed
    // rows, so a steady layout bumps no mtime and triggers no re-render; a moved
    // tab bumps the mtime and the 0.5s watch repaints on the next tick.
    func maybeOrder() {
        guard !orderInFlight else { return }
        guard !readSessions().isEmpty else { return }
        guard let bin = tabChromaBin() else { return }
        orderInFlight = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["sessions", "order"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.orderInFlight = false }
        }
        do { try p.run() } catch { orderInFlight = false }
    }

    func updateTitle() {
        let sessions = readSessions()
        let title = menuBarTitle(sessions)
        // Idle (no sessions): dim the ○ so it recedes into the menu bar.
        let attrs: [NSAttributedString.Key: Any] =
            sessions.isEmpty ? [.foregroundColor: NSColor.tertiaryLabelColor] : [:]
        statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: attrs)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = readSessions()
        let now = Int(Date().timeIntervalSince1970)

        if sessions.isEmpty {
            menu.addItem(disabledItem("No active sessions"))
        } else {
            menu.addItem(disabledItem("\(sessions.count) active session\(sessions.count == 1 ? "" : "s")"))
            let sorted = orderedForDisplay(sessions) {
                (arank($0.agent), rank($0.state), -$0.updated)
                    < (arank($1.agent), rank($1.state), -$1.updated)
            }
            let showDetail = UserDefaults.standard.bool(forKey: showTtyPidKey)
            for s in sorted {
                let label = s.label.isEmpty ? "(no label)" : s.label
                let ap = agentPrefix ? "\(aletter(s.agent)) " : ""
                var title = "\(ap)\(emoji(s.state))  \(label) — \(s.state) (\(fmtAge(now - s.updated)))"
                // When "Show tty & pid" is on, append pid + tty inline. This makes
                // the shared-pane case legible: sessions on the same tty all focus
                // the same iTerm tab, because the tty IS the focus key.
                if showDetail {
                    let pid = s.pid.map(String.init) ?? "—"
                    let tty = s.tty.isEmpty ? "—" : s.tty.replacingOccurrences(of: "/dev/", with: "")
                    title += "   ·   pid \(pid)  \(tty)"
                }
                // Single click focuses; the leading emoji conveys color, row text
                // stays default-color for readability.
                let item = NSMenuItem(title: title, action: #selector(focusSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.key
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Show tty & pid", action: #selector(toggleShowTtyPid), keyEquivalent: "")
        toggle.target = self
        toggle.state = UserDefaults.standard.bool(forKey: showTtyPidKey) ? .on : .off
        menu.addItem(toggle)
        let prune = NSMenuItem(title: "Prune dead", action: #selector(pruneDead), keyEquivalent: "")
        prune.target = self
        menu.addItem(prune)
        let quit = NSMenuItem(title: "Quit TabChroma Lights", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func disabledItem(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc func focusSession(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { runTabChroma(["sessions", "focus", key]) }
    }

    @objc func toggleShowTtyPid() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: showTtyPidKey), forKey: showTtyPidKey)
        // Menu closes on click; the dropdown is rebuilt fresh on next open, and
        // the menu-bar title is unaffected by this view-only toggle.
    }

    @objc func pruneDead() {
        runTabChroma(["sessions", "prune"])
        lastSignature = -1   // force a title refresh on the next tick
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar agent: no Dock icon, no main window
app.run()
