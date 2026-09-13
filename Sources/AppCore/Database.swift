import Foundation
import SQLite3
import ActionKit
import MailKit

/// Base SQLite locale : historique des réunions, liste de tags réutilisables, et **étape de
/// workflow** de chaque réunion (pour reprendre après un échec). Remplace l'ancien index JSON.
/// Fin wrapper sur `libsqlite3` (module fourni par le SDK macOS) — pas de dépendance ajoutée.
///
/// ponytail: accès depuis le seul `@MainActor` du coordinateur (écritures rares, petites) ; passer
/// à un actor dédié seulement si le volume l'exige.
public final class Database {
    private var db: OpaquePointer?
    public let path: URL
    private var initializationError: Error?

    // SQLite copie la valeur liée immédiatement (nécessaire car nos String C sont temporaires).
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL) {
        self.path = path
        // L'app doit pouvoir afficher l'erreur d'ouverture. Toute opération la propage ensuite.
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try check(sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil))
            try exec("PRAGMA foreign_keys = ON;")
            try transaction {
                try exec(Self.schema)
                try migrate()
            }
        } catch {
            initializationError = error
            sqlite3_close(db)
            db = nil
        }
    }

    /// Migrations additives pour les bases déjà créées (CREATE TABLE IF NOT EXISTS n'ajoute pas de
    /// colonne à une table existante).
    private func migrate() throws {
        let existing = Set(try query("PRAGMA table_info(meeting)") { self.colText($0, 1) ?? "" })
        if !existing.contains("participants") {
            try exec("ALTER TABLE meeting ADD COLUMN participants TEXT NOT NULL DEFAULT '';")
        }
        if !existing.contains("user_notes") {
            try exec("ALTER TABLE meeting ADD COLUMN user_notes TEXT NOT NULL DEFAULT '';")
        }
        if !existing.contains("project_id") {
            try exec("ALTER TABLE meeting ADD COLUMN project_id TEXT REFERENCES project(id) ON DELETE SET NULL;")
        }
        let actionColumns = Set(try query("PRAGMA table_info(action)") { self.colText($0, 1) ?? "" })
        if !actionColumns.contains("source_url") {
            try exec("ALTER TABLE action ADD COLUMN source_url TEXT;")
        }
        if !actionColumns.contains("project_id") {
            try exec("ALTER TABLE action ADD COLUMN project_id TEXT REFERENCES project(id) ON DELETE SET NULL;")
        }
        // NULL = implication déduite du responsable ; la colonne n'est écrite qu'en cas de surcharge
        // manuelle. Les lignes existantes se classent donc toutes seules.
        if !actionColumns.contains("involvement") {
            try exec("ALTER TABLE action ADD COLUMN involvement TEXT;")
        }
    }

    deinit { sqlite3_close(db) }

    /// `~/Library/Application Support/Pepito/pepito.db` (même dossier que le journal).
    public static func defaultLocation() -> Database {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return Database(path: base.appending(path: "Pepito/pepito.db"))
    }

    static let schema = """
    CREATE TABLE IF NOT EXISTS project(
      id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'active',
      color TEXT, owner TEXT, created_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS meeting(
      id TEXT PRIMARY KEY, title TEXT NOT NULL,
      started_at REAL NOT NULL, ended_at REAL,
      status TEXT NOT NULL, folder_path TEXT NOT NULL,
      session_dir TEXT, transcript TEXT, last_error TEXT, updated_at REAL NOT NULL,
      participants TEXT NOT NULL DEFAULT '');
    CREATE TABLE IF NOT EXISTS tag(name TEXT PRIMARY KEY, created_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS meeting_tag(
      meeting_id TEXT NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
      tag_name TEXT NOT NULL REFERENCES tag(name) ON DELETE CASCADE,
      PRIMARY KEY(meeting_id, tag_name));
    CREATE TABLE IF NOT EXISTS action(
      id TEXT PRIMARY KEY,
      meeting_id TEXT REFERENCES meeting(id) ON DELETE CASCADE,
      parent_id TEXT, title TEXT NOT NULL, details TEXT NOT NULL DEFAULT '',
      owner TEXT, due REAL, status TEXT NOT NULL, priority INTEGER NOT NULL,
      created_at REAL NOT NULL, source_url TEXT);
    -- Supprimer un projet ne doit jamais supprimer d'actions : SET NULL, pas CASCADE.
    -- (project_id / involvement sont ajoutés par migrate() sur les bases existantes.)
    CREATE TABLE IF NOT EXISTS mail_item(
      review_date TEXT NOT NULL, idx INTEGER NOT NULL,
      subject TEXT NOT NULL, sender TEXT NOT NULL, url TEXT NOT NULL,
      message_count INTEGER NOT NULL, unread INTEGER NOT NULL, flagged INTEGER NOT NULL,
      bucket TEXT, importance TEXT NOT NULL DEFAULT '', action TEXT NOT NULL DEFAULT '',
      deadline TEXT NOT NULL DEFAULT '', why TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '',
      action_id TEXT,
      PRIMARY KEY(review_date, idx));
    """

    // MARK: - API

    /// Toutes les réunions, plus récente en tête, tags inclus.
    public func loadAll() throws -> [Meeting] {
        var meetings = try query(
            "SELECT id,title,started_at,ended_at,status,folder_path,session_dir,transcript,last_error,participants,user_notes,project_id"
            + " FROM meeting ORDER BY started_at DESC") { Self.buildMeeting($0) }
            .compactMap { $0 }
        for i in meetings.indices { meetings[i].tags = try tags(for: meetings[i].id) }
        return meetings
    }

    /// Insère ou met à jour une réunion (par `id`) et réécrit ses liaisons de tags.
    public func save(_ m: Meeting) throws {
        try transaction {
            try run("""
                INSERT INTO meeting(id,title,started_at,ended_at,status,folder_path,session_dir,transcript,last_error,updated_at,participants,user_notes,project_id)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, started_at=excluded.started_at,
                  ended_at=excluded.ended_at, status=excluded.status, folder_path=excluded.folder_path,
                  session_dir=excluded.session_dir, transcript=excluded.transcript,
                  last_error=excluded.last_error, updated_at=excluded.updated_at,
                  participants=excluded.participants, user_notes=excluded.user_notes,
                  project_id=excluded.project_id
                """) { s in
                try self.text(s, 1, m.id.uuidString); try self.text(s, 2, m.title)
                try self.real(s, 3, m.startedAt.timeIntervalSince1970)
                try self.real(s, 4, m.endedAt?.timeIntervalSince1970)
                try self.text(s, 5, m.status.rawValue); try self.text(s, 6, m.folderPath)
                try self.text(s, 7, m.sessionDirPath); try self.text(s, 8, m.transcript)
                try self.text(s, 9, m.lastError); try self.real(s, 10, Date().timeIntervalSince1970)
                try self.text(s, 11, Self.encodeStrings(m.participants)); try self.text(s, 12, m.userNotes)
                try self.text(s, 13, m.projectID?.uuidString)
            }
            try addTags(m.tags)
            try run("DELETE FROM meeting_tag WHERE meeting_id=?") { try self.text($0, 1, m.id.uuidString) }
            for tag in m.tags where !tag.isEmpty {
                try run("INSERT OR IGNORE INTO meeting_tag(meeting_id,tag_name) VALUES(?,?)") { s in
                    try self.text(s, 1, m.id.uuidString); try self.text(s, 2, tag)
                }
            }
        }
    }

    /// Supprime une réunion ; ses tags liés et ses actions tombent par cascade FK (foreign_keys=ON).
    public func delete(_ id: UUID) throws {
        try run("DELETE FROM meeting WHERE id=?") { try self.text($0, 1, id.uuidString) }
    }

    /// Liste des tags connus, triée (alimente le sélecteur de la fenêtre de nommage).
    public func allTags() throws -> [String] {
        try query("SELECT name FROM tag ORDER BY name") { self.colText($0, 0) ?? "" }
            .filter { !$0.isEmpty }
    }

    /// Enregistre de nouveaux tags (idempotent).
    public func addTags(_ tags: [String]) throws {
        try transaction {
            for t in tags where !t.isEmpty {
                try run("INSERT OR IGNORE INTO tag(name,created_at) VALUES(?,?)") { s in
                    try self.text(s, 1, t); try self.real(s, 2, Date().timeIntervalSince1970)
                }
            }
        }
    }

    // MARK: - Plans d'action (persistés pour survivre au relancement et au suivi cross-réunion)

    /// Insère/met à jour un lot d'actions (par `id`). Le statut existant est **préservé** en cas de
    /// re-traitement (on n'écrase pas un suivi manuel), le reste est rafraîchi.
    /// `involvement` est préservé pour la même raison : une surcharge manuelle survit à une relance
    /// du pipeline. `updateAction` la réécrit explicitement (comme pour le statut).
    public func saveActions(_ items: [ActionItem]) throws {
        try transaction {
            for a in items {
                try run("""
                    INSERT INTO action(id,meeting_id,parent_id,title,details,owner,due,status,priority,created_at,source_url,project_id,involvement)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET meeting_id=excluded.meeting_id, parent_id=excluded.parent_id,
                      title=excluded.title, details=excluded.details, owner=excluded.owner,
                      due=excluded.due, priority=excluded.priority, source_url=excluded.source_url,
                      project_id=excluded.project_id
                    """) { s in
                    try self.text(s, 1, a.id.uuidString); try self.text(s, 2, a.meetingID?.uuidString)
                    try self.text(s, 3, a.parentID?.uuidString); try self.text(s, 4, a.title)
                    try self.text(s, 5, a.details); try self.text(s, 6, a.owner)
                    try self.real(s, 7, a.dueDate?.timeIntervalSince1970)
                    try self.text(s, 8, a.status.rawValue); try self.int(s, 9, Int32(a.priority.rawValue))
                    try self.real(s, 10, Date().timeIntervalSince1970); try self.text(s, 11, a.sourceURL)
                    try self.text(s, 12, a.projectID?.uuidString); try self.text(s, 13, a.involvement?.rawValue)
                }
            }
        }
    }

    /// Pose ou retire la surcharge d'implication (`nil` = revenir à la déduction automatique).
    public func updateInvolvement(_ id: UUID, _ involvement: Involvement?) throws {
        try run("UPDATE action SET involvement=? WHERE id=?") { s in
            try self.text(s, 1, involvement?.rawValue); try self.text(s, 2, id.uuidString)
        }
    }

    /// Toutes les actions persistées (rechargées au démarrage, sinon le suivi serait perdu).
    public func loadAllActions() throws -> [ActionItem] {
        try query(Self.actionSelect + " ORDER BY created_at") { Self.buildAction($0) }.compactMap { $0 }
    }

    /// Actions ouvertes toutes réunions confondues (socle du suivi/pré-brief cross-réunion).
    public func allOpenActions() throws -> [ActionItem] {
        try query(Self.actionSelect + " WHERE status IN ('todo','in-progress','blocked') ORDER BY created_at") {
            Self.buildAction($0)
        }.compactMap { $0 }
    }

    /// Met à jour le seul statut d'une action (édition UI, auto-résolution cross-réunion).
    public func updateStatus(_ id: UUID, _ status: ActionStatus) throws {
        try run("UPDATE action SET status=? WHERE id=?") { s in
            try self.text(s, 1, status.rawValue); try self.text(s, 2, id.uuidString)
        }
    }

    // MARK: - Revues de mails (historique consultable dans l'app)

    /// Enregistre une revue. Retrier le même jour **remplace** la revue précédente, comme le
    /// document Markdown du Vault est réécrit.
    public func saveMailReview(_ entries: [MailReviewEntry]) throws {
        try transaction {
            guard let date = entries.first?.reviewDate else { return }
            try run("DELETE FROM mail_item WHERE review_date=?") { try self.text($0, 1, date) }
            for e in entries {
                try run("""
                    INSERT INTO mail_item(review_date,idx,subject,sender,url,message_count,unread,flagged,
                      bucket,importance,action,deadline,why,summary,action_id)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """) { s in
                    try self.text(s, 1, e.reviewDate); try self.int(s, 2, Int32(e.index))
                    try self.text(s, 3, e.subject); try self.text(s, 4, e.sender); try self.text(s, 5, e.url)
                    try self.int(s, 6, Int32(e.messageCount)); try self.int(s, 7, Int32(e.unread))
                    try self.int(s, 8, e.flagged ? 1 : 0)
                    try self.text(s, 9, e.bucket?.rawValue); try self.text(s, 10, e.importance)
                    try self.text(s, 11, e.action); try self.text(s, 12, e.deadline)
                    try self.text(s, 13, e.why); try self.text(s, 14, e.summary)
                    try self.text(s, 15, e.actionID?.uuidString)
                }
            }
        }
    }

    /// Historique des revues, plus récente en tête, avec ses compteurs (agrégés en SQL — pas de
    /// table de revue séparée à tenir à jour). `immediateCount` est ce qui **reste** à traiter :
    /// une conversation dont l'action est terminée ou abandonnée en sort, comme dans la revue.
    public func mailReviews() throws -> [MailReviewSummary] {
        try query("""
            SELECT m.review_date, SUM(m.message_count), COUNT(*),
              SUM(m.bucket='immediate' AND (a.status IS NULL OR a.status NOT IN ('done','dropped'))),
              SUM(m.flagged), SUM(m.action_id IS NOT NULL)
            FROM mail_item m LEFT JOIN action a ON a.id = m.action_id
            GROUP BY m.review_date ORDER BY m.review_date DESC
            """) { s in
            MailReviewSummary(
                date: Self.column(s, 0) ?? "",
                messageCount: Int(Self.columnInt(s, 1)),
                threadCount: Int(Self.columnInt(s, 2)),
                immediateCount: Int(Self.columnInt(s, 3)),
                flaggedCount: Int(Self.columnInt(s, 4)),
                actionCount: Int(Self.columnInt(s, 5)))
        }.filter { !$0.date.isEmpty }
    }

    /// Conversations d'une revue, dans l'ordre du digest.
    public func mailReview(date: String) throws -> [MailReviewEntry] {
        try query("""
            SELECT review_date,idx,subject,sender,url,message_count,unread,flagged,
              bucket,importance,action,deadline,why,summary,action_id
            FROM mail_item WHERE review_date=? ORDER BY idx
            """, bind: { try self.text($0, 1, date) }) { s in
            MailReviewEntry(
                reviewDate: Self.column(s, 0) ?? date,
                index: Int(Self.columnInt(s, 1)),
                subject: Self.column(s, 2) ?? "", sender: Self.column(s, 3) ?? "",
                url: Self.column(s, 4) ?? "",
                messageCount: Int(Self.columnInt(s, 5)), unread: Int(Self.columnInt(s, 6)),
                flagged: Self.columnInt(s, 7) != 0,
                bucket: Self.column(s, 8).flatMap { MailBucket(rawValue: $0) },
                importance: Self.column(s, 9) ?? "", action: Self.column(s, 10) ?? "",
                deadline: Self.column(s, 11) ?? "", why: Self.column(s, 12) ?? "",
                summary: Self.column(s, 13) ?? "",
                actionID: Self.column(s, 14).flatMap { UUID(uuidString: $0) })
        }
    }

    /// Supprime une revue de l'historique (les actions créées, elles, restent dans le suivi).
    public func deleteMailReview(date: String) throws {
        try run("DELETE FROM mail_item WHERE review_date=?") { try self.text($0, 1, date) }
    }

    private static let actionSelect =
        "SELECT id,meeting_id,parent_id,title,details,owner,due,status,priority,source_url,project_id,involvement"
        + " FROM action"

    private static func buildAction(_ s: OpaquePointer?) -> ActionItem? {
        guard let idStr = column(s, 0), let id = UUID(uuidString: idStr),
              let title = column(s, 3), let statusRaw = column(s, 7),
              let status = ActionStatus(rawValue: statusRaw) else { return nil }
        return ActionItem(
            id: id,
            parentID: column(s, 2).flatMap { UUID(uuidString: $0) },
            meetingID: column(s, 1).flatMap { UUID(uuidString: $0) },
            projectID: column(s, 10).flatMap { UUID(uuidString: $0) },
            title: title, details: column(s, 4) ?? "", owner: column(s, 5),
            dueDate: columnDouble(s, 6).map { Date(timeIntervalSince1970: $0) },
            status: status,
            priority: ActionPriority(rawValue: Int(columnInt(s, 8))) ?? .medium,
            involvement: column(s, 11).flatMap { Involvement(rawValue: $0) },
            sourceURL: column(s, 9))
    }

    // MARK: - Projets

    /// Tous les projets, actifs d'abord puis par nom.
    public func loadProjects() throws -> [Project] {
        try query("SELECT id,name,status,color,owner FROM project ORDER BY status, name") { s -> Project? in
            guard let idStr = Self.column(s, 0), let id = UUID(uuidString: idStr),
                  let name = Self.column(s, 1) else { return nil }
            return Project(
                id: id, name: name,
                status: Self.column(s, 2).flatMap { ProjectStatus(rawValue: $0) } ?? .active,
                color: Self.column(s, 3), owner: Self.column(s, 4))
        }.compactMap { $0 }
    }

    public func saveProject(_ p: Project) throws {
        try run("""
            INSERT INTO project(id,name,status,color,owner,created_at) VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, status=excluded.status,
              color=excluded.color, owner=excluded.owner
            """) { s in
            try self.text(s, 1, p.id.uuidString); try self.text(s, 2, p.name)
            try self.text(s, 3, p.status.rawValue); try self.text(s, 4, p.color)
            try self.text(s, 5, p.owner); try self.real(s, 6, Date().timeIntervalSince1970)
        }
    }

    /// Supprime un projet. Ses actions et réunions restent, `project_id` repasse à NULL par le
    /// `ON DELETE SET NULL` du schéma.
    public func deleteProject(_ id: UUID) throws {
        try run("DELETE FROM project WHERE id=?") { try self.text($0, 1, id.uuidString) }
    }

    private func tags(for id: UUID) throws -> [String] {
        try query("SELECT tag_name FROM meeting_tag WHERE meeting_id=? ORDER BY tag_name",
              bind: { try self.text($0, 1, id.uuidString) }) { self.colText($0, 0) ?? "" }
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
            participants: decodeStrings(column(s, 9)),
            status: status,
            projectID: column(s, 11).flatMap { UUID(uuidString: $0) },
            folderPath: folder,
            sessionDirPath: column(s, 6), transcript: column(s, 7),
            userNotes: column(s, 10) ?? "", lastError: column(s, 8))
    }

    /// Encodage JSON d'une liste de chaînes (participants) — robuste aux virgules dans les noms.
    private static func encodeStrings(_ v: [String]) -> String {
        guard let data = try? JSONEncoder().encode(v) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
    private static func decodeStrings(_ s: String?) -> [String] {
        guard let s, let data = s.data(using: .utf8),
              let v = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return v
    }

    // MARK: - Bas niveau

    private var errmsg: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "Base indisponible" }

    private func check(_ code: Int32) throws {
        if let initializationError { throw initializationError }
        guard code == SQLITE_OK else { throw DatabaseError(code: code, message: errmsg) }
    }

    /// Regroupe les écritures liées. Les opérations imbriquées participent à la transaction appelante.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try check(SQLITE_OK)
        guard sqlite3_get_autocommit(db) != 0 else { return try body() }
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            // Garder l'erreur initiale, même si SQLite a déjà annulé la transaction (disque plein).
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        try check(SQLITE_OK)
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func run(_ sql: String, _ bind: (OpaquePointer?) throws -> Void = { _ in }) throws {
        try check(SQLITE_OK)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        try bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw DatabaseError(code: rc, message: errmsg) }
    }

    private func query<T>(
        _ sql: String,
        bind: (OpaquePointer?) throws -> Void = { _ in },
        row: (OpaquePointer?) -> T
    ) throws -> [T] {
        try check(SQLITE_OK)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        try bind(stmt)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { throw DatabaseError(code: rc, message: errmsg) }
            out.append(row(stmt))
        }
    }

    private func text(_ s: OpaquePointer?, _ i: Int32, _ v: String) throws {
        try check(sqlite3_bind_text(s, i, v, -1, transient))
    }
    private func text(_ s: OpaquePointer?, _ i: Int32, _ v: String?) throws {
        if let v { try text(s, i, v) } else { try check(sqlite3_bind_null(s, i)) }
    }
    private func real(_ s: OpaquePointer?, _ i: Int32, _ v: Double?) throws {
        if let v { try check(sqlite3_bind_double(s, i, v)) } else { try check(sqlite3_bind_null(s, i)) }
    }
    private func int(_ s: OpaquePointer?, _ i: Int32, _ v: Int32) throws {
        try check(sqlite3_bind_int(s, i, v))
    }
    private func colText(_ s: OpaquePointer?, _ i: Int32) -> String? { Self.column(s, i) }

    private static func column(_ s: OpaquePointer?, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
    private static func columnDouble(_ s: OpaquePointer?, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }
    private static func columnInt(_ s: OpaquePointer?, _ i: Int32) -> Int32 {
        sqlite3_column_int(s, i)
    }
}

/// Erreur SQLite propagée jusqu'à l'interface ; ne contient ni requête SQL ni valeurs liées.
public struct DatabaseError: LocalizedError {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { "SQLite (\(code)) : \(message)" }
}
