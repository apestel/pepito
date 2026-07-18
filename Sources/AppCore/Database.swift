import Foundation
import SQLite3

/// Base SQLite locale : historique des réunions, liste de tags réutilisables, et **étape de
/// workflow** de chaque réunion (pour reprendre après un échec). Remplace l'ancien index JSON.
/// Fin wrapper sur `libsqlite3` (module fourni par le SDK macOS) — pas de dépendance ajoutée.
///
/// ponytail: accès depuis le seul `@MainActor` du coordinateur (écritures rares, petites) ; passer
/// à un actor dédié seulement si le volume l'exige.
public final class Database {
    private var db: OpaquePointer?
    public let path: URL

    // SQLite copie la valeur liée immédiatement (nécessaire car nos String C sont temporaires).
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL) {
        self.path = path
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            AppLog.shared.log("SQLite ouverture échouée : \(errmsg)", level: "ERROR")
        }
        exec("PRAGMA foreign_keys = ON;")
        exec(Self.schema)
    }

    deinit { sqlite3_close(db) }

    /// `~/Library/Application Support/Pepito/pepito.db` (même dossier que le journal).
    public static func defaultLocation() -> Database {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return Database(path: base.appending(path: "Pepito/pepito.db"))
    }

    static let schema = """
    CREATE TABLE IF NOT EXISTS meeting(
      id TEXT PRIMARY KEY, title TEXT NOT NULL,
      started_at REAL NOT NULL, ended_at REAL,
      status TEXT NOT NULL, folder_path TEXT NOT NULL,
      session_dir TEXT, transcript TEXT, last_error TEXT, updated_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS tag(name TEXT PRIMARY KEY, created_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS meeting_tag(
      meeting_id TEXT NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
      tag_name TEXT NOT NULL REFERENCES tag(name) ON DELETE CASCADE,
      PRIMARY KEY(meeting_id, tag_name));
    """

    // MARK: - API

    /// Toutes les réunions, plus récente en tête, tags inclus.
    public func loadAll() -> [Meeting] {
        var meetings = query(
            "SELECT id,title,started_at,ended_at,status,folder_path,session_dir,transcript,last_error"
            + " FROM meeting ORDER BY started_at DESC") { Self.buildMeeting($0) }
            .compactMap { $0 }
        for i in meetings.indices { meetings[i].tags = tags(for: meetings[i].id) }
        return meetings
    }

    /// Insère ou met à jour une réunion (par `id`) et réécrit ses liaisons de tags.
    public func save(_ m: Meeting) {
        run("""
            INSERT INTO meeting(id,title,started_at,ended_at,status,folder_path,session_dir,transcript,last_error,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, started_at=excluded.started_at,
              ended_at=excluded.ended_at, status=excluded.status, folder_path=excluded.folder_path,
              session_dir=excluded.session_dir, transcript=excluded.transcript,
              last_error=excluded.last_error, updated_at=excluded.updated_at
            """) { s in
            self.text(s, 1, m.id.uuidString); self.text(s, 2, m.title)
            self.real(s, 3, m.startedAt.timeIntervalSince1970)
            self.real(s, 4, m.endedAt?.timeIntervalSince1970)
            self.text(s, 5, m.status.rawValue); self.text(s, 6, m.folderPath)
            self.text(s, 7, m.sessionDirPath); self.text(s, 8, m.transcript)
            self.text(s, 9, m.lastError); self.real(s, 10, Date().timeIntervalSince1970)
        }
        addTags(m.tags)
        run("DELETE FROM meeting_tag WHERE meeting_id=?") { self.text($0, 1, m.id.uuidString) }
        for tag in m.tags where !tag.isEmpty {
            run("INSERT OR IGNORE INTO meeting_tag(meeting_id,tag_name) VALUES(?,?)") { s in
                self.text(s, 1, m.id.uuidString); self.text(s, 2, tag)
            }
        }
    }

    /// Liste des tags connus, triée (alimente le sélecteur de la fenêtre de nommage).
    public func allTags() -> [String] {
        query("SELECT name FROM tag ORDER BY name") { self.colText($0, 0) ?? "" }
            .filter { !$0.isEmpty }
    }

    /// Enregistre de nouveaux tags (idempotent).
    public func addTags(_ tags: [String]) {
        for t in tags where !t.isEmpty {
            run("INSERT OR IGNORE INTO tag(name,created_at) VALUES(?,?)") { s in
                self.text(s, 1, t); self.real(s, 2, Date().timeIntervalSince1970)
            }
        }
    }

    private func tags(for id: UUID) -> [String] {
        query("SELECT tag_name FROM meeting_tag WHERE meeting_id=? ORDER BY tag_name",
              bind: { self.text($0, 1, id.uuidString) }) { self.colText($0, 0) ?? "" }
            .filter { !$0.isEmpty }
    }

    private static func buildMeeting(_ s: OpaquePointer?) -> Meeting? {
        guard let idStr = column(s, 0), let id = UUID(uuidString: idStr),
              let title = column(s, 1), let started = columnDouble(s, 2),
              let statusRaw = column(s, 4), let status = MeetingStatus(rawValue: statusRaw),
              let folder = column(s, 5) else { return nil }
        return Meeting(
            id: id, title: title,
            startedAt: Date(timeIntervalSince1970: started),
            endedAt: columnDouble(s, 3).map { Date(timeIntervalSince1970: $0) },
            status: status, folderPath: folder,
            sessionDirPath: column(s, 6), transcript: column(s, 7), lastError: column(s, 8))
    }

    // MARK: - Bas niveau

    private var errmsg: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "?" }

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            AppLog.shared.log("SQLite exec échoué : \(errmsg) — \(sql.prefix(60))", level: "ERROR")
        }
    }

    private func run(_ sql: String, _ bind: (OpaquePointer?) -> Void = { _ in }) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            AppLog.shared.log("SQLite prepare échoué : \(errmsg)", level: "ERROR"); return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            AppLog.shared.log("SQLite step échoué : \(errmsg)", level: "ERROR")
        }
    }

    private func query<T>(
        _ sql: String,
        bind: (OpaquePointer?) -> Void = { _ in },
        row: (OpaquePointer?) -> T
    ) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            AppLog.shared.log("SQLite prepare échoué : \(errmsg)", level: "ERROR"); return []
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    private func text(_ s: OpaquePointer?, _ i: Int32, _ v: String) {
        sqlite3_bind_text(s, i, v, -1, transient)
    }
    private func text(_ s: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(s, i, v, -1, transient) } else { sqlite3_bind_null(s, i) }
    }
    private func real(_ s: OpaquePointer?, _ i: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(s, i, v) } else { sqlite3_bind_null(s, i) }
    }

    private func colText(_ s: OpaquePointer?, _ i: Int32) -> String? { Self.column(s, i) }

    private static func column(_ s: OpaquePointer?, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
    private static func columnDouble(_ s: OpaquePointer?, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }
}
