import CLibXML2
import Foundation
import Testing
@testable import NWZCore

struct DatabaseTests {
    @Test func systemHTMLParserIsAvailable() throws {
        let html = "<p>中文<b>内容</b>"
        let document = try #require(htmlReadMemory(html, Int32(html.utf8.count), nil, "UTF-8", Int32(HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NONET.rawValue)))
        defer { xmlFreeDoc(document) }
        #expect(xmlDocGetRootElement(document) != nil)
    }

    @Test func migrationsPersistAndRunOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let migrations = [Database.Migration(version: 1, sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, text TEXT)")]
        let database = try Database(path: path, migrations: migrations)
        try await database.execute("INSERT INTO items VALUES (?, ?)", [.integer(1), .text("中文内容")])
        let reopened = try Database(path: path, migrations: migrations)
        #expect(try await reopened.query("PRAGMA user_version").first?["user_version"] == .integer(1))
        #expect(try await reopened.query("SELECT text FROM items").first?["text"] == .text("中文内容"))
    }

    @Test func failedMigrationRollsBack() async throws {
        let database = try Database()
        do {
            try await database.migrate([.init(version: 1, sql: "CREATE TABLE items(id); INVALID SQL")])
            Issue.record("错误的迁移不应成功")
        } catch {}
        #expect(try await database.query("PRAGMA user_version").first?["user_version"] == .integer(0))
        #expect(try await database.query("SELECT name FROM sqlite_master WHERE name = 'items'").isEmpty)
    }

    @Test func transactionsCommitAndRollBack() async throws {
        let database = try Database(migrations: [.init(version: 1, sql: "CREATE TABLE items(id INTEGER UNIQUE)")])
        try await database.transaction { db in try db.execute("INSERT INTO items VALUES (?)", [.integer(1)]) }
        do {
            try await database.transaction { db in
                try db.execute("INSERT INTO items VALUES (?)", [.integer(2)])
                try db.execute("INSERT INTO items VALUES (?)", [.integer(1)])
            }
            Issue.record("重复主键应使事务回滚")
        } catch {}
        #expect(try await database.query("SELECT id FROM items") == [["id": .integer(1)]])
    }

    @Test func bindsAllTypesWithoutTruncation() async throws {
        let database = try Database()
        let values: [SQLValue] = [.null, .integer(Int64.max), .real(1.5), .text("甲\0乙'"), .blob(Data([0, 255])), .blob(Data())]
        let row = try #require(await database.query("SELECT ? AS a, ? AS b, ? AS c, ? AS d, ? AS e, ? AS f", values).first)
        #expect(["a", "b", "c", "d", "e", "f"].compactMap { row[$0] } == values)
        await #expect(throws: DatabaseError.self) { try await database.query("SELECT ?", []) }
    }

    @Test func trigramSearchAndTriggers() async throws {
        let database = try Database(migrations: [.init(version: 1, sql: """
            CREATE TABLE pages(id INTEGER PRIMARY KEY, title TEXT, body TEXT);
            CREATE VIRTUAL TABLE pages_fts USING fts5(title, body, content=pages, content_rowid=id, tokenize=trigram);
            CREATE TRIGGER pages_insert AFTER INSERT ON pages BEGIN
                INSERT INTO pages_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
            END;
            CREATE TRIGGER pages_delete AFTER DELETE ON pages BEGIN
                INSERT INTO pages_fts(pages_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
            END;
            CREATE TRIGGER pages_update AFTER UPDATE ON pages BEGIN
                INSERT INTO pages_fts(pages_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
                INSERT INTO pages_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
            END;
            """)])
        try await database.execute("INSERT INTO pages VALUES (1, '开发说明', '工作空间搜索')")
        #expect(try await database.query("SELECT rowid FROM pages_fts WHERE pages_fts MATCH ?", [.text("工作空")]).count == 1)
        try await database.execute("UPDATE pages SET body = '新的文档' WHERE id = 1")
        #expect(try await database.query("SELECT rowid FROM pages_fts WHERE pages_fts MATCH ?", [.text("工作空")]).isEmpty)
        try await database.execute("DELETE FROM pages")
        #expect(try await database.query("SELECT rowid FROM pages_fts WHERE pages_fts MATCH ?", [.text("新的文")]).isEmpty)
    }

    @Test func actorSerializesConcurrentTransactions() async throws {
        let database = try Database(migrations: [.init(version: 1, sql: "CREATE TABLE counter(value INTEGER); INSERT INTO counter VALUES(0)")])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { try await database.transaction { db in try db.execute("UPDATE counter SET value = value + 1") } }
            }
            try await group.waitForAll()
        }
        #expect(try await database.query("SELECT value FROM counter").first?["value"] == .integer(50))
    }
}
