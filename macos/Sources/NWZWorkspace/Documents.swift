import Foundation
import NWZCore

extension Workspace {
    public func docs(kind: String) async throws -> [DocSummary] {
        try await database.transaction { db in
            try Store.list(Doc.self, table: "doc", condition: "deleted=0 AND kind=?", values: [.text(kind)], order: "pinned DESC,sort,updated_at DESC", db: db).map(Self.summary)
        }
    }
    public func fullDocs(kind: String) async throws -> [Doc] {
        try await database.transaction { db in
            try Store.list(Doc.self, table: "doc", condition: "deleted=0 AND kind=?", values: [.text(kind)], order: "sort,created_at", db: db)
        }
    }
    public func doc(_ id: String) async throws -> Doc? {
        try await database.transaction { db in try Store.load(Doc.self, table: "doc", id: id, db: db) }
    }
    public func daily(_ day: String) async throws -> Doc {
        if let doc = try await doc("daily-" + day), !doc.deleted { return doc }
        return Doc(id: "daily-" + day, kind: "daily", title: day, day: day)
    }
    public func dailyDays() async throws -> [String] {
        try await database.query("SELECT day FROM records WHERE type='doc' AND kind='daily' AND deleted=0 AND json_extract(json,'$.content')!='' ORDER BY day DESC").compactMap { $0["day"]?.string }
    }
    public func saveDoc(_ input: DocInput) async throws -> Doc {
        try await database.transaction { db in
            let old = try input.id.flatMap { try Store.load(Doc.self, table: "doc", id: $0, db: db) }
            let time = Self.stamp(old?.updatedAt ?? 0), kind = input.kind.isEmpty ? "note" : input.kind
            let id = input.id ?? Self.newID()
            var doc = try old ?? Doc(id: id, kind: kind, sort: Store.sort("doc", kind: kind, parent: input.parentId, db: db), day: id.hasPrefix("daily-") ? String(id.dropFirst(6)) : nil, createdAt: time)
            try Self.checkParent(id, parent: input.parentId, db: db)
            doc.title = input.title; doc.content = input.content; doc.parentId = input.parentId; doc.pinned = input.pinned
            doc.tags = input.tags.reduce(into: []) { result, tag in
                let cleaned = String(tag.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "#" }))
                if !cleaned.isEmpty && !result.contains(cleaned) { result.append(cleaned) }
            }
            doc.sourceSystem = input.sourceSystem ?? doc.sourceSystem; doc.sourceKey = input.sourceKey ?? doc.sourceKey; doc.sourceUrl = input.sourceUrl ?? doc.sourceUrl
            doc.publishedUrl = input.publishedUrl ?? doc.publishedUrl
            doc.baseAt = old?.updatedAt ?? 0; doc.updatedAt = time; doc.updatedBy = self.deviceID; doc.deleted = false
            try Store.write(doc, db: db)
            return doc
        }
    }
    public func setPublished(_ id: String, url: String) async throws -> Doc {
        try await updateDoc(id) { $0.publishedUrl = url }
    }
    public func setSourceURL(_ id: String, url: String) async throws -> Doc {
        try await updateDoc(id) { $0.sourceUrl = url }
    }
    private func updateDoc(_ id: String, change: @escaping @Sendable (inout Doc) -> Void) async throws -> Doc {
        try await database.transaction { db in
            guard var doc = try Store.load(Doc.self, table: "doc", id: id, db: db) else { throw NWZError.other("文档不存在") }
            doc.baseAt = doc.updatedAt; doc.updatedAt = Self.stamp(doc.updatedAt); doc.updatedBy = self.deviceID
            change(&doc)
            try Store.write(doc, db: db)
            return doc
        }
    }
    private static func checkParent(_ id: String, parent: String?, db: isolated Database) throws {
        var cursor = parent, visited: Set<String> = [id]
        while let current = cursor {
            guard visited.insert(current).inserted else { throw NWZError.other("不能移动到自己的下级页面") }
            cursor = try Store.load(Doc.self, table: "doc", id: current, db: db)?.parentId
        }
    }
    public func moveDoc(_ id: String, parentId: String?, sort: Double) async throws -> Doc {
        try await database.transaction { db in
            try Self.checkParent(id, parent: parentId, db: db)
            guard var doc = try Store.load(Doc.self, table: "doc", id: id, db: db) else { throw NWZError.other("文档不存在") }
            doc.parentId = parentId; doc.sort = sort; doc.baseAt = doc.updatedAt; doc.updatedAt = Self.stamp(doc.updatedAt); doc.updatedBy = self.deviceID
            try Store.write(doc, db: db)
            return doc
        }
    }
    public func deleteDoc(_ id: String) async throws -> Int {
        try await database.transaction { db in
            var queue = [id], visited: Set<String> = [], count = 0
            while let current = queue.popLast() {
                guard visited.insert(current).inserted else { continue }
                queue += try db.query("SELECT id FROM records WHERE type='doc' AND parent_id=? AND deleted=0", [.text(current)]).compactMap { $0["id"]?.string }
                guard var doc = try Store.load(Doc.self, table: "doc", id: current, db: db), !doc.deleted else { continue }
                doc.deleted = true; doc.baseAt = doc.updatedAt; doc.updatedAt = Self.stamp(doc.updatedAt); doc.updatedBy = self.deviceID
                try Store.write(doc, db: db); count += 1
            }
            return count
        }
    }
    public func tags() async throws -> [TagCount] {
        try await database.query("SELECT j.value AS name,COUNT(*) AS count FROM records r,json_each(r.json,'$.tags') j WHERE r.type='doc' AND r.deleted=0 GROUP BY j.value ORDER BY count DESC,name").map {
            TagCount(name: $0["name"]?.string ?? "", count: Int($0["count"]?.integer ?? 0))
        }
    }
    static func summary(_ doc: Doc) -> DocSummary {
        DocSummary(id: doc.id, kind: doc.kind, title: doc.title, excerpt: String(References.plainText(doc.content).prefix(140)), parentId: doc.parentId, sort: doc.sort, tags: doc.tags, day: doc.day, pinned: doc.pinned, sourceSystem: doc.sourceSystem, sourceKey: doc.sourceKey, publishedUrl: doc.publishedUrl, updatedAt: doc.updatedAt)
    }
}
