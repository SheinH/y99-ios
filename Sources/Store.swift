import Foundation
import SQLite3

// On-disk cache, one SQLite database per account (Application Support/y99-<username>.sqlite), so chats
// and friends open instantly and offline, and switching accounts keeps each one's history.
// Messages are stored as the server's own JSON objects, keyed by (chat, id), and never deleted.
@MainActor final class Store {
    static private(set) var current: Store?

    static func open(username: String) {
        guard current?.username != username else { return }
        current = username.isEmpty ? nil : Store(username: username)
        Task { @MainActor in Outbox.shared.kick() }   // send anything this account left queued
    }
    static func close() { current = nil }

    let username: String
    nonisolated(unsafe) private var db: OpaquePointer?

    private init?(username: String) {
        self.username = username
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = username.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        let path = dir.appendingPathComponent("y99-\(String(safe)).sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS messages(chat TEXT NOT NULL, id INTEGER NOT NULL, raw TEXT NOT NULL,
                PRIMARY KEY(chat, id)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS chats(chat TEXT PRIMARY KEY, read_id INTEGER DEFAULT 0,
                delivered_id INTEGER DEFAULT 0, marked_seen INTEGER DEFAULT 0, draft TEXT DEFAULT '');
            CREATE TABLE IF NOT EXISTS friends(username TEXT PRIMARY KEY, status INTEGER, position INTEGER);
            CREATE TABLE IF NOT EXISTS outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL,
                json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS confirmed(msg_id INTEGER PRIMARY KEY);
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Messages

    /// Inserts or updates server messages (objects with a numeric `id`); newer flags overwrite older.
    func save(chat: String, _ objs: [[String: Any]]) {
        guard !objs.isEmpty else { return }
        exec("BEGIN")
        for o in objs {
            guard let id = Int("\(o["id"] ?? "")"),
                  let data = try? JSONSerialization.data(withJSONObject: o),
                  let raw = String(data: data, encoding: .utf8) else { continue }
            run("INSERT OR REPLACE INTO messages(chat, id, raw) VALUES(?, ?, ?)", chat, id, raw)
        }
        exec("COMMIT")
    }

    /// Up to `limit` stored messages older than `before` (or the newest ones), oldest first.
    func messages(chat: String, before: Int? = nil, limit: Int) -> [[String: Any]] {
        let rows = query("SELECT raw FROM messages WHERE chat = ? AND id < ? ORDER BY id DESC LIMIT ?",
                         chat, before ?? Int.max, limit)
        return rows.reversed().compactMap { r in
            (r[0] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }

    func newestId(chat: String) -> Int? {
        query("SELECT MAX(id) FROM messages WHERE chat = ?", chat).first?[0] as? Int
    }

    // MARK: Per-chat state

    struct ChatState { var readId = 0, deliveredId = 0, markedSeen = 0, draft = "" }

    func state(chat: String) -> ChatState {
        guard let r = query("SELECT read_id, delivered_id, marked_seen, draft FROM chats WHERE chat = ?", chat).first
        else { return ChatState() }
        return ChatState(readId: r[0] as? Int ?? 0, deliveredId: r[1] as? Int ?? 0,
                         markedSeen: r[2] as? Int ?? 0, draft: r[3] as? String ?? "")
    }

    func save(chat: String, state s: ChatState) {
        run("INSERT OR REPLACE INTO chats(chat, read_id, delivered_id, marked_seen, draft) VALUES(?, ?, ?, ?, ?)",
            chat, s.readId, s.deliveredId, s.markedSeen, s.draft)
    }

    // MARK: Friends

    func friends() -> [(username: String, status: Int)] {
        query("SELECT username, status FROM friends ORDER BY position").compactMap { r in
            (r[0] as? String).map { ($0, r[1] as? Int ?? 3) }
        }
    }

    func saveFriends(_ list: [(username: String, status: Int)]) {
        exec("BEGIN")
        exec("DELETE FROM friends")
        for (i, f) in list.enumerated() {
            run("INSERT INTO friends(username, status, position) VALUES(?, ?, ?)", f.username, f.status, i)
        }
        exec("COMMIT")
    }

    // MARK: Outbox (Outbox.swift); entries kept in insertion order

    func outbox() -> [String] { query("SELECT json FROM outbox ORDER BY seq").compactMap { $0[0] as? String } }
    func addOutbox(id: String, json: String) { run("INSERT INTO outbox(id, json) VALUES(?, ?)", id, json) }
    func updateOutbox(id: String, json: String) { run("UPDATE outbox SET json = ? WHERE id = ?", json, id) }
    func removeOutbox(id: String) { run("DELETE FROM outbox WHERE id = ?", id) }

    /// Message ids the outbox has already matched to a send, so two identical messages aren't both
    /// claimed by one server message when checking whether an unconfirmed send went through.
    func confirm(_ msgId: Int) { run("INSERT OR IGNORE INTO confirmed(msg_id) VALUES(?)", msgId) }
    func isConfirmed(_ msgId: Int) -> Bool { !query("SELECT 1 FROM confirmed WHERE msg_id = ?", msgId).isEmpty }

    // MARK: SQLite plumbing

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)   // SQLITE_TRANSIENT

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func prepare(_ sql: String, _ args: [Any]) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as String: sqlite3_bind_text(st, n, v, -1, Self.transient)
            default: sqlite3_bind_null(st, n)
            }
        }
        return st
    }

    private func run(_ sql: String, _ args: Any...) {
        let st = prepare(sql, args)
        sqlite3_step(st)
        sqlite3_finalize(st)
    }

    private func query(_ sql: String, _ args: Any...) -> [[Any?]] {
        guard let st = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(st) }
        var rows: [[Any?]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(st)).map { c in
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: Int(sqlite3_column_int64(st, c))
                case SQLITE_TEXT: String(cString: sqlite3_column_text(st, c))
                default: nil
                }
            })
        }
        return rows
    }
}
