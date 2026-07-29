import Foundation
import SQLite3

/// Crée une base au **schéma d'avant les projets**, pour vérifier que `Database.migrate()` rattrape
/// une installation existante sans perdre ses actions. `Database` ajoute toujours les colonnes à
/// l'ouverture : impossible de tester la migration avec lui.
struct LegacyDatabaseFixture {
    private var db: OpaquePointer?

    init(path: URL) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        exec("""
            CREATE TABLE action(
              id TEXT PRIMARY KEY, meeting_id TEXT, parent_id TEXT,
              title TEXT NOT NULL, details TEXT NOT NULL DEFAULT '',
              owner TEXT, due REAL, status TEXT NOT NULL, priority INTEGER NOT NULL,
              created_at REAL NOT NULL, source_url TEXT);
            """)
    }

    func insertLegacyAction(id: UUID, title: String, owner: String) {
        exec("""
            INSERT INTO action(id,title,details,owner,status,priority,created_at)
            VALUES('\(id.uuidString)','\(title)','','\(owner)','todo',1,0);
            """)
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    func close() { sqlite3_close(db) }
}
