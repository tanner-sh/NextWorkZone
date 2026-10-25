import CryptoKit
import Foundation
import NWZCore

/// 剪贴板历史：保存复制过的文字、图片和文件，支持搜索、按类型和来源筛选、置顶板（收藏）。
///
/// 数据保存在本机的 SQLite 数据库中，图片另存为 PNG 文件（原图和缩略图）。相同内容只保存一份，
/// 再次复制时移到最前面。置顶板中的条目不会被自动清理。
public actor ClipboardStore {
    /// 列表中每条文字最多返回的字符数（卡片只显示开头一部分）。
    static let previewChars = 800
    /// 超过这个长度的文字不保存（多半是误复制的整份文件）。
    public static let maxTextBytes = 4 * 1024 * 1024
    /// HTML 超过这个长度时只保存纯文本。
    static let maxHTMLBytes = 1024 * 1024
    /// 缩略图的最大尺寸。
    static let thumbSize = 480

    private let database: Database
    /// 数据所在的文件夹。
    public nonisolated let directory: URL

    public init(directory: URL) throws {
        for sub in ["images", "thumbs", "icons"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        self.directory = directory
        database = try Database(path: directory.appendingPathComponent("clipboard.sqlite").path, migrations: [.init(version: 1, sql: Self.schema)])
    }

    private static let schema = """
    CREATE TABLE items (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        hash TEXT NOT NULL UNIQUE,
        text TEXT NOT NULL DEFAULT '',
        html TEXT,
        title TEXT NOT NULL DEFAULT '',
        image_width INTEGER,
        image_height INTEGER,
        image_bytes INTEGER,
        files TEXT,
        app_id TEXT,
        app_name TEXT,
        created_at INTEGER NOT NULL,
        copied_at INTEGER NOT NULL,
        copy_count INTEGER NOT NULL DEFAULT 1,
        pinboard TEXT,
        pinned_at INTEGER
    );
    CREATE INDEX items_copied ON items (copied_at DESC);
    CREATE INDEX items_pinboard ON items (pinboard, pinned_at DESC);
    CREATE TABLE pinboards (id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, sort REAL NOT NULL);
    CREATE TABLE apps (id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT, has_icon INTEGER NOT NULL DEFAULT 0);
    CREATE VIRTUAL TABLE search USING fts5(id UNINDEXED, body, tokenize = 'trigram');
    """

    // MARK: 路径

    public nonisolated func imageURL(_ id: String) -> URL { directory.appendingPathComponent("images/\(Self.safeName(id)).png") }
    public nonisolated func thumbURL(_ id: String) -> URL { directory.appendingPathComponent("thumbs/\(Self.safeName(id)).png") }
    public nonisolated func iconURL(_ appID: String) -> URL { directory.appendingPathComponent("icons/\(String(Self.hash([Data(appID.utf8)]).prefix(24))).png") }

    /// 只保留 id 中可以用作文件名的字符。
    static func safeName(_ id: String) -> String { String(id.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }.map(Character.init)) }

    /// 各部分带上长度再求哈希，避免拼接后不同内容得到相同的输入。
    static func hash(_ parts: [Data]) -> String {
        var hasher = SHA256()
        for part in parts {
            withUnsafeBytes(of: UInt64(part.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: part)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: 记录

    /// 保存一份新复制的内容。相同内容已存在时把它移到最前面并返回 `(条目, false)`。
    /// 内容为空或过大时返回 nil。
    public func add(_ capture: Capture) async throws -> (item: ClipItem, isNew: Bool)? {
        let kind: String, text: String, html: String?, files: String?, itemHash: String
        if !capture.files.isEmpty {
            let joined = capture.files.joined(separator: "\n")
            (kind, text, html, files, itemHash) = (ClipKind.file, "", nil, joined, Self.hash([Data("file".utf8), Data(joined.utf8)]))
        } else if let value = capture.text, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard value.utf8.count <= Self.maxTextBytes else { return nil }
            (kind, text, html, files, itemHash) = (ClipKind.of(value), value, capture.html.flatMap { $0.utf8.count <= Self.maxHTMLBytes ? $0 : nil }, nil, Self.hash([Data("text".utf8), Data(value.utf8)]))
        } else if let image = capture.image {
            let size = withUnsafeBytes(of: UInt32(image.width).littleEndian) { Data($0) } + withUnsafeBytes(of: UInt32(image.height).littleEndian) { Data($0) }
            (kind, text, html, files, itemHash) = (ClipKind.image, "", nil, nil, Self.hash([Data("image".utf8), size, image.pixels]))
        } else {
            return nil
        }
        let appID = capture.app?.id, appName = capture.app?.name
        let existing: String? = try await database.transaction { db in
            guard let id = try db.query("SELECT id FROM items WHERE hash = ?", [.text(itemHash)]).first?["id"]?.string else { return nil }
            // 再次复制：移到最前面；来源记为最近一次复制的应用，网页上复制的格式可能更完整
            try db.execute("UPDATE items SET copied_at = ?, copy_count = copy_count + 1, app_id = COALESCE(?, app_id), app_name = COALESCE(?, app_name), html = COALESCE(?, html) WHERE id = ?",
                           [.integer(try Self.nextCopiedAt(db)), Self.value(appID), Self.value(appName), Self.value(html), .text(id)])
            return id
        }
        if let existing { return try await item(existing).map { ($0, false) } }

        let id = UUID().uuidString.lowercased()
        let meta: ClipImage? = if kind == ClipKind.image, let image = capture.image { try saveImage(id, image) } else { nil }
        try await database.transaction { db in
            let now = try Self.nextCopiedAt(db)
            try db.execute("INSERT INTO items (id, kind, hash, text, html, image_width, image_height, image_bytes, files, app_id, app_name, created_at, copied_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                           [.text(id), .text(kind), .text(itemHash), .text(text), Self.value(html), meta.map { .integer(Int64($0.width)) } ?? .null, meta.map { .integer(Int64($0.height)) } ?? .null,
                            meta.map { .integer(Int64($0.bytes)) } ?? .null, Self.value(files), Self.value(appID), Self.value(appName), .integer(now), .integer(now)])
            try db.execute("INSERT INTO search (id, body) VALUES (?, ?)", [.text(id), .text(Self.searchBody(text: text, title: "", files: files, app: appName))])
        }
        return try await item(id).map { ($0, true) }
    }

    /// 复制时间严格递增：同一毫秒内连续复制时，最近复制的仍排在最前。
    private static func nextCopiedAt(_ db: isolated Database) throws -> Int64 {
        let latest = try db.query("SELECT COALESCE(MAX(copied_at), 0) AS latest FROM items").first?["latest"]?.integer ?? 0
        return max(now(), latest + 1)
    }

    /// 保存原图和缩略图。
    private func saveImage(_ id: String, _ image: RGBAImage) throws -> ClipImage {
        guard let cg = ClipImages.cgImage(image), let png = ClipImages.png(cg) else { throw NWZError.other("图片数据不完整") }
        try png.write(to: imageURL(id), options: .atomic)
        guard let thumb = ClipImages.scaled(cg, max: Self.thumbSize).flatMap(ClipImages.png) else { throw NWZError.other("保存缩略图失败") }
        try thumb.write(to: thumbURL(id), options: .atomic)
        return ClipImage(width: image.width, height: image.height, bytes: png.count)
    }

    // MARK: 读取

    private static let itemColumns = "i.id, i.kind, substr(i.text, 1, \(previewChars)) AS preview, length(i.text) AS text_length, i.html IS NOT NULL AS has_html, i.title, i.image_width, i.image_height, i.image_bytes, i.files, i.app_id, i.app_name, a.color AS app_color, COALESCE(a.has_icon, 0) AS app_icon, i.created_at, i.copied_at, i.copy_count, i.pinboard"

    private static func selectItems(_ clause: String) -> String { "SELECT \(itemColumns) FROM items i LEFT JOIN apps a ON a.id = i.app_id \(clause)" }

    private static func item(_ row: [String: SQLValue]) -> ClipItem {
        func int(_ key: String) -> Int64? { row[key]?.integer }
        func text(_ key: String) -> String? { row[key]?.string }
        let image = int("image_width").flatMap { w in int("image_height").map { ClipImage(width: Int(w), height: Int($0), bytes: Int(int("image_bytes") ?? 0)) } }
        return ClipItem(id: text("id") ?? "", kind: text("kind") ?? ClipKind.text, text: text("preview") ?? "", textLength: Int(int("text_length") ?? 0), hasHtml: int("has_html") == 1,
                        title: text("title") ?? "", image: image, files: text("files").map { $0.components(separatedBy: "\n") } ?? [], appId: text("app_id"), appName: text("app_name"),
                        appColor: text("app_color"), appIcon: int("app_icon") == 1, createdAt: int("created_at") ?? 0, copiedAt: int("copied_at") ?? 0, copyCount: Int(int("copy_count") ?? 1), pinboard: text("pinboard"))
    }

    public func item(_ id: String) async throws -> ClipItem? {
        try await database.query(Self.selectItems("WHERE i.id = ?"), [.text(id)]).first.map(Self.item)
    }

    /// 写回剪贴板所需的完整内容。
    public func content(_ id: String) async throws -> ClipContent? {
        guard let row = try await database.query("SELECT kind, text, html, files FROM items WHERE id = ?", [.text(id)]).first else { return nil }
        let kind = row["kind"]?.string ?? ClipKind.text
        return ClipContent(id: id, kind: kind, text: row["text"]?.string ?? "", html: row["html"]?.string, image: kind == ClipKind.image ? imageURL(id) : nil,
                           files: row["files"]?.string.map { $0.components(separatedBy: "\n") } ?? [])
    }

    /// 按条件列出，最近复制的在前；置顶板中按置顶时间排列。
    public func list(_ query: ClipQuery) async throws -> [ClipItem] {
        var conditions: [String] = [], values: [SQLValue] = []
        let text = (query.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // trigram 索引至少需要 3 个字符，更短的关键词逐条匹配
            if text.count >= 3 {
                conditions.append("i.id IN (SELECT id FROM search WHERE search MATCH ?)")
                values.append(.text("\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""))
            } else {
                conditions.append("i.id IN (SELECT id FROM search WHERE body LIKE ? ESCAPE '\\')")
                values.append(.text("%\(text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"))
            }
        }
        if let kind = query.kind, !kind.isEmpty { conditions.append("i.kind = ?"); values.append(.text(kind)) }
        var pinnedOrder = false
        if let board = query.pinboard, !board.isEmpty {
            pinnedOrder = true
            if board == "*" { conditions.append("i.pinboard IS NOT NULL") } else { conditions.append("i.pinboard = ?"); values.append(.text(board)) }
        }
        if let app = query.app, !app.isEmpty { conditions.append("i.app_id = ?"); values.append(.text(app)) }
        // 同一毫秒内复制的条目按写入顺序，后写入的在前
        let order = pinnedOrder ? "i.pinned_at DESC, i.rowid DESC" : "i.copied_at DESC, i.rowid DESC"
        if let before = query.before { conditions.append(pinnedOrder ? "i.pinned_at < ?" : "i.copied_at < ?"); values.append(.integer(before)) }
        let clause = (conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")) + " ORDER BY \(order) LIMIT \(min(query.limit ?? 100, 1000))"
        return try await database.query(Self.selectItems(clause), values).map(Self.item)
    }

    // MARK: 修改

    /// 标记为刚刚使用（粘贴、拖出时调用），移到最前面。
    public func touch(_ ids: [String]) async throws {
        let now = Self.now()
        try await database.transaction { db in
            // 多条一起粘贴时保持原来的先后顺序
            for (offset, id) in ids.enumerated() {
                try db.execute("UPDATE items SET copied_at = ?, copy_count = copy_count + 1 WHERE id = ?", [.integer(now - Int64(offset)), .text(id)])
            }
        }
    }

    public func delete(_ ids: [String]) async throws {
        try await database.transaction { db in
            for id in ids {
                try db.execute("DELETE FROM items WHERE id = ?", [.text(id)])
                try db.execute("DELETE FROM search WHERE id = ?", [.text(id)])
            }
        }
        for id in ids {
            try? FileManager.default.removeItem(at: imageURL(id))
            try? FileManager.default.removeItem(at: thumbURL(id))
        }
    }

    /// 清空历史，置顶的条目保留。返回删除的条数。
    public func clearHistory() async throws -> Int {
        let ids = try await database.query("SELECT id FROM items WHERE pinboard IS NULL").compactMap { $0["id"]?.string }
        try await delete(ids)
        return ids.count
    }

    /// 清理过期的历史：超过 `keepDays` 天（0 表示不限）或超出 `maxItems` 条（0 表示不限）的未置顶条目。
    public func prune(keepDays: Int, maxItems: Int) async throws -> Int {
        let cutoff = keepDays == 0 ? Int64.min : Self.now() - Int64(keepDays) * 86_400_000
        let offset = maxItems == 0 ? Int64.max : Int64(maxItems)
        let ids = try await database.query("""
            SELECT id FROM items WHERE pinboard IS NULL AND (copied_at < ? OR id IN (
                SELECT id FROM items WHERE pinboard IS NULL ORDER BY copied_at DESC, rowid DESC LIMIT -1 OFFSET ?))
            """, [.integer(cutoff), .integer(offset)]).compactMap { $0["id"]?.string }
        try await delete(ids)
        return ids.count
    }

    /// 修改文字内容（编辑后保存）。内容与另一条相同时合并到那一条。返回修改后的条目。
    public func updateText(_ id: String, text: String) async throws -> ClipItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= Self.maxTextBytes else { throw NWZError.other("内容为空或过长") }
        let newHash = Self.hash([Data("text".utf8), Data(text.utf8)])
        if let other = try await database.query("SELECT id FROM items WHERE hash = ?", [.text(newHash)]).first?["id"]?.string, other != id {
            try await delete([id])
            return try await item(other)
        }
        try await database.transaction { db in
            try db.execute("UPDATE items SET text = ?, html = NULL, hash = ?, kind = ? WHERE id = ? AND kind NOT IN ('image', 'file')", [.text(text), .text(newHash), .text(ClipKind.of(text)), .text(id)])
            try Self.reindex(id, db)
        }
        return try await item(id)
    }

    /// 给条目起名字（为空表示取消）。
    public func rename(_ id: String, title: String) async throws -> ClipItem? {
        try await database.transaction { db in
            try db.execute("UPDATE items SET title = ? WHERE id = ?", [.text(title.trimmingCharacters(in: .whitespacesAndNewlines)), .text(id)])
            try Self.reindex(id, db)
        }
        return try await item(id)
    }

    private static func reindex(_ id: String, _ db: isolated Database) throws {
        let row = try db.query("SELECT text, title, files, app_name FROM items WHERE id = ?", [.text(id)]).first
        try db.execute("DELETE FROM search WHERE id = ?", [.text(id)])
        if let row {
            let body = searchBody(text: row["text"]?.string ?? "", title: row["title"]?.string ?? "", files: row["files"]?.string, app: row["app_name"]?.string)
            try db.execute("INSERT INTO search (id, body) VALUES (?, ?)", [.text(id), .text(body)])
        }
    }

    // MARK: 置顶板

    /// 放入置顶板（nil 表示取消置顶）。
    public func setPinboard(_ ids: [String], pinboard: String?) async throws {
        let now = Self.now()
        try await database.transaction { db in
            for (offset, id) in ids.enumerated() {
                try db.execute("UPDATE items SET pinboard = ?, pinned_at = ? WHERE id = ?", [Self.value(pinboard), pinboard == nil ? .null : .integer(now - Int64(offset)), .text(id)])
            }
        }
    }

    public func pinboards() async throws -> [Pinboard] {
        try await database.query("SELECT p.id, p.name, p.color, p.sort, (SELECT COUNT(*) FROM items WHERE pinboard = p.id) AS count FROM pinboards p ORDER BY p.sort, p.name").map { row in
            let sort: Double = switch row["sort"] { case .real(let v): v; case .integer(let v): Double(v); default: 0 }
            return Pinboard(id: row["id"]?.string ?? "", name: row["name"]?.string ?? "", color: row["color"]?.string ?? "", sort: sort, count: Int(row["count"]?.integer ?? 0))
        }
    }

    /// 新建（`id` 为空）或修改置顶板。
    public func savePinboard(id: String?, name: String, color: String) async throws -> Pinboard {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NWZError.other("请输入名称") }
        let id = try await database.transaction { db -> String in
            if let id, !id.isEmpty {
                try db.execute("UPDATE pinboards SET name = ?, color = ? WHERE id = ?", [.text(name), .text(color), .text(id)])
                return id
            }
            let id = UUID().uuidString.lowercased()
            let sort: Double = switch try db.query("SELECT COALESCE(MAX(sort), 0) + 1 AS sort FROM pinboards").first?["sort"] { case .real(let v): v; case .integer(let v): Double(v); default: 1 }
            try db.execute("INSERT INTO pinboards (id, name, color, sort) VALUES (?, ?, ?, ?)", [.text(id), .text(name), .text(color), .real(sort)])
            return id
        }
        guard let board = try await pinboards().first(where: { $0.id == id }) else { throw NWZError.other("置顶板不存在") }
        return board
    }

    /// 删除置顶板，其中的条目回到历史中（取消置顶）。
    public func deletePinboard(_ id: String) async throws {
        let now = Self.now()
        try await database.transaction { db in
            try db.execute("UPDATE items SET pinboard = NULL, pinned_at = NULL, copied_at = MAX(copied_at, ?) WHERE pinboard = ?", [.integer(now - 1), .text(id)])
            try db.execute("DELETE FROM pinboards WHERE id = ?", [.text(id)])
        }
    }

    /// 调整置顶板的顺序：按给定的 id 顺序排列。
    public func orderPinboards(_ ids: [String]) async throws {
        try await database.transaction { db in
            for (index, id) in ids.enumerated() { try db.execute("UPDATE pinboards SET sort = ? WHERE id = ?", [.real(Double(index)), .text(id)]) }
        }
    }

    // MARK: 来源应用

    /// 是否已记录过这个应用的图标和颜色。
    public func hasApp(_ appID: String) async throws -> Bool {
        try await !database.query("SELECT 1 AS found FROM apps WHERE id = ?", [.text(appID)]).isEmpty
    }

    /// 记录应用的名称和图标（PNG），并从图标中取主色。
    public func saveApp(_ appID: String, name: String, iconPNG: Data?) async throws {
        var color: String?
        if let png = iconPNG {
            try png.write(to: iconURL(appID), options: .atomic)
            color = ClipImages.decode(png).flatMap(ClipImages.dominantColor)
        }
        try await database.execute("""
            INSERT INTO apps (id, name, color, has_icon) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color, has_icon = excluded.has_icon
            """, [.text(appID), .text(name), Self.value(color), .integer(iconPNG == nil ? 0 : 1)])
    }

    /// 出现过的来源应用及条数，条数多的在前。
    public func apps() async throws -> [ClipApp] {
        try await database.query("""
            SELECT i.app_id, MAX(i.app_name) AS name, a.color, COALESCE(a.has_icon, 0) AS icon, COUNT(*) AS count FROM items i LEFT JOIN apps a ON a.id = i.app_id
            WHERE i.app_id IS NOT NULL GROUP BY i.app_id ORDER BY COUNT(*) DESC
            """).map { ClipApp(id: $0["app_id"]?.string ?? "", name: $0["name"]?.string ?? "", color: $0["color"]?.string, icon: $0["icon"]?.integer == 1, count: Int($0["count"]?.integer ?? 0)) }
    }

    public func stats() async throws -> ClipStats {
        let row = try await database.query("SELECT COUNT(*) AS items, COUNT(pinboard) AS pinned, COALESCE(SUM(image_bytes), 0) AS bytes FROM items").first
        return ClipStats(items: Int(row?["items"]?.integer ?? 0), pinned: Int(row?["pinned"]?.integer ?? 0), imageBytes: row?["bytes"]?.integer ?? 0)
    }

    static func searchBody(text: String, title: String, files: String?, app: String?) -> String {
        [title, text, files ?? "", app ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func value(_ text: String?) -> SQLValue { text.map(SQLValue.text) ?? .null }
}
