import Foundation
import NWZCore

extension Workspace {
    public func backlinks(system: String, key: String) async throws -> [Backlink] {
        try await database.query("SELECT r.* FROM refs f JOIN records r ON r.type=f.item_type AND r.id=f.item_id WHERE f.system=? AND f.key=? AND r.deleted=0 ORDER BY r.updated_at DESC", [.text(system), .text(key)]).map { row in
            Backlink(itemType: row["type"]?.string ?? "", id: row["id"]?.string ?? "", kind: row["kind"]?.string ?? "", title: row["title"]?.string ?? "", done: row["done"]?.integer == 1, updatedAt: row["updated_at"]?.integer ?? 0)
        }
    }
    public func search(_ query: String, limit: Int = 30) async throws -> [SearchHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, limit > 0 else { return [] }
        let indexed = text.unicodeScalars.count >= 3
        let condition = indexed ? "search MATCH ?" : "(instr(lower(s.title),lower(?))>0 OR instr(lower(s.body),lower(?))>0)"
        let parameters: [SQLValue] = indexed ? [.text("\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"")] : [.text(text), .text(text)]
        return try await database.query("SELECT s.item_type,s.item_id,s.title,s.body,r.kind,r.done FROM search s JOIN records r ON r.type=s.item_type AND r.id=s.item_id WHERE \(condition) ORDER BY \(indexed ? "rank" : "r.updated_at DESC") LIMIT ?", parameters + [.integer(Int64(limit))]).map { row in
            SearchHit(itemType: row["item_type"]?.string ?? "", id: row["item_id"]?.string ?? "", kind: row["kind"]?.string ?? "", title: row["title"]?.string ?? "", snippet: References.snippet(row["body"]?.string ?? "", query: text), done: row["done"]?.integer == 1)
        }
    }
    public func saveAsset(mime: String, data: Data) async throws -> AssetMeta {
        let asset = AssetMeta(id: Self.newID(), mime: mime, createdAt: Self.now())
        try await database.execute("INSERT INTO assets VALUES (?,?,?,?,1)", [.text(asset.id), .text(mime), .blob(data), .integer(asset.createdAt)])
        return asset
    }
    public func asset(_ id: String) async throws -> (mime: String, data: Data)? {
        guard let row = try await database.query("SELECT mime,data FROM assets WHERE id=? AND data IS NOT NULL", [.text(id)]).first, case .blob(let data) = row["data"] else { return nil }
        return (row["mime"]?.string ?? "application/octet-stream", data)
    }
}
