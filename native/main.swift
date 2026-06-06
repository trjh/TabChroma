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
//   TAB_CHROMA_REGISTRY_DB      registry path (default: Application Support)
//   TAB_CHROMA_LIGHTS_COLLAPSE  collapse threshold (default 8; 0 disables)
//   TAB_CHROMA_BIN              path to tab-chroma.sh for focus/prune actions

import AppKit
import Foundation
import SQLite3

// ── Config ───────────────────────────────────────────────────────────────────
let environment = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser.path
let dbPath = environment["TAB_CHROMA_REGISTRY_DB"]
    ?? "\(home)/Library/Application Support/TabChroma/sessions.sqlite3"
let collapseThreshold = Int(environment["TAB_CHROMA_LIGHTS_COLLAPSE"] ?? "8") ?? 8

let stateEmoji: [String: String] = [
    "working": "🔵", "done": "🟢", "attention": "🟠",
    "permission": "🔴", "starting": "⚪", "ended": "⚫",
]
let stateRank: [String: Int] = [
    "permission": 0, "attention": 1, "working": 2, "done": 3, "starting": 4, "ended": 5,
]
let agentRank: [String: Int] = ["claude": 0, "codex": 1]

func emoji(_ s: String) -> String { stateEmoji[s] ?? "⚪" }
func rank(_ s: String) -> Int { stateRank[s] ?? 99 }
func arank(_ a: String) -> Int { agentRank[a] ?? 99 }

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
    let sql = "SELECT session_key, agent, state, label, color_r, color_g, color_b, updated_at "
        + "FROM sessions WHERE expires_at IS NULL OR expires_at >= ? ORDER BY updated_at DESC"
    var stmt: OpaquePointer?
    // A failed prepare most commonly means the table does not exist yet (no hook
    // has written) — treat that as idle rather than an error.
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
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
            r: intOrNil(4), g: intOrNil(5), b: intOrNil(6), updated: intOrNil(7) ?? now))
    }
    return rows
}

// Menu-bar string: one circle per session (most urgent first), collapsed to
// grouped counts past the threshold — matching the SwiftBar reader.
func menuBarTitle(_ sessions: [Session]) -> String {
    if sessions.isEmpty { return "○" }
    if collapseThreshold > 0 && sessions.count > collapseThreshold {
        var counts: [String: Int] = [:]
        for s in sessions { counts[s.state, default: 0] += 1 }
        return counts.keys.sorted { rank($0) < rank($1) }
            .map { "\(emoji($0))×\(counts[$0]!)" }
            .joined(separator: " ")
    }
    return sessions
        .sorted { (rank($0.state), -$0.updated) < (rank($1.state), -$1.updated) }
        .map { emoji($0.state) }
        .joined(separator: " ")
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

// ── App ───────────────────────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var lastSignature: Double = -1
    var timer: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.title = "○"
        menu.delegate = self            // dropdown rebuilt fresh on each open (ages current)
        statusItem.menu = menu
        updateTitle()

        // Watch the registry: re-render the menu-bar title only when the DB
        // (or its WAL/SHM) actually changes. A 0.5s in-process stat() is
        // negligible and has none of SwiftBar's per-tick python respawn cost.
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
    }

    func updateTitle() {
        statusItem.button?.title = menuBarTitle(readSessions())
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = readSessions()
        let now = Int(Date().timeIntervalSince1970)

        if sessions.isEmpty {
            menu.addItem(disabledItem("No active sessions"))
        } else {
            menu.addItem(disabledItem("\(sessions.count) active session\(sessions.count == 1 ? "" : "s")"))
            let sorted = sessions.sorted {
                (arank($0.agent), rank($0.state), -$0.updated)
                    < (arank($1.agent), rank($1.state), -$1.updated)
            }
            for s in sorted {
                let label = s.label.isEmpty ? "(no label)" : s.label
                let title = "\(emoji(s.state))  \(label) — \(s.state) (\(fmtAge(now - s.updated)))"
                let item = NSMenuItem(title: title, action: #selector(focusSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.key
                if let r = s.r, let g = s.g, let b = s.b {
                    item.attributedTitle = NSAttributedString(string: title, attributes: [
                        .foregroundColor: NSColor(srgbRed: CGFloat(r) / 255.0,
                                                  green: CGFloat(g) / 255.0,
                                                  blue: CGFloat(b) / 255.0, alpha: 1.0),
                    ])
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
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
