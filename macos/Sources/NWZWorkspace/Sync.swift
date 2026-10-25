import Foundation
import NWZCore

extension Workspace {
    /// 调用者传入 v2 同步根目录；每个设备只追加自己的日志。
    public func sync(at directory: URL) async throws -> SyncReport {
        try await database.transaction { db in
            let root = directory.standardizedFileURL.path
            if try db.query("SELECT value FROM meta WHERE key='sync-root'").first?["value"]?.string != root {
                try db.execute("UPDATE records SET dirty=1")
                try db.execute("UPDATE assets SET dirty=1 WHERE data IS NOT NULL")
                try db.execute("DELETE FROM sync_cursors")
                try db.execute("INSERT OR REPLACE INTO meta VALUES ('sync-root',?)", [.text(root)])
            }
            let devices = directory.appendingPathComponent("devices"), assets = directory.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let ownLog = devices.appendingPathComponent(self.deviceID + ".jsonl")
            var report = SyncReport(exported: try Synchronizer.export(db: db, file: ownLog, assets: assets, device: self.deviceID))
            for file in try FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "jsonl" {
                let device = file.deletingPathExtension().lastPathComponent
                if device == self.deviceID { continue }
                report.devices += 1
                let imported = try Synchronizer.importLog(db: db, file: file, assets: assets, device: device, me: self.deviceID)
                report.imported += imported.0; report.conflicts += imported.1
            }
            for row in try db.query("SELECT id FROM assets WHERE data IS NULL") {
                guard let id = row["id"]?.string, Synchronizer.safeID(id), let data = try? Data(contentsOf: assets.appendingPathComponent(id)) else { continue }
                try db.execute("UPDATE assets SET data=? WHERE id=?", [.blob(data), .text(id)])
            }
            report.finishedAt = Self.now()
            return report
        }
    }
}

private enum Synchronizer {
    static func safeID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    static func line<T: Encodable>(_ type: String, _ row: T) throws -> Data {
        var data = try JSONEncoder().encode(JSONValue.object(["type": .string(type), "row": .from(row)]))
        data.append(10)
        return data
    }
    static func assetMeta(_ row: [String: SQLValue]) -> AssetMeta {
        .init(id: row["id"]?.string ?? "", mime: row["mime"]?.string ?? "", createdAt: row["created_at"]?.integer ?? 0)
    }
    static func export(db: isolated Database, file: URL, assets: URL, device: String) throws -> Int {
        let records = try db.query("SELECT type,json FROM records WHERE dirty=1")
        let images = try db.query("SELECT * FROM assets WHERE dirty=1 AND data IS NOT NULL")
        guard !records.isEmpty || !images.isEmpty else { return 0 }
        var output = Data()
        for row in images {
            let meta = assetMeta(row)
            guard safeID(meta.id), case .blob(let data) = row["data"] else { throw NWZError.other("图片记录无效") }
            let path = assets.appendingPathComponent(meta.id)
            if !FileManager.default.fileExists(atPath: path.path) { try data.write(to: path, options: .atomic) }
            output.append(try line("asset", meta))
        }
        for row in records {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data((row["json"]?.string ?? "").utf8))
            output.append(try line(row["type"]?.string ?? "", value))
        }
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        // 如果上次写入被中断，先舍弃自己日志末尾的半行；脏标记仍在数据库内。
        let existing = try handle.readToEnd() ?? Data()
        let complete = existing.lastIndex(of: 10).map { $0 + 1 } ?? 0
        if complete != existing.count { try handle.truncate(atOffset: UInt64(complete)) }
        try handle.seekToEnd(); try handle.write(contentsOf: output); try handle.synchronize()
        if complete + output.count > 8 * 1024 * 1024 { try compact(db: db, file: file, device: device) }
        try db.execute("UPDATE records SET dirty=0 WHERE dirty=1")
        try db.execute("UPDATE assets SET dirty=0 WHERE dirty=1 AND data IS NOT NULL")
        return records.count + images.count
    }
    static func compact(db: isolated Database, file: URL, device: String) throws {
        var output = try line("header", ["generation": Workspace.newID()])
        for row in try db.query("SELECT id,mime,created_at FROM assets WHERE data IS NOT NULL") { output.append(try line("asset", assetMeta(row))) }
        for row in try db.query("SELECT type,json FROM records WHERE updated_by=?", [.text(device)]) {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data((row["json"]?.string ?? "").utf8))
            output.append(try line(row["type"]?.string ?? "", value))
        }
        try output.write(to: file, options: .atomic)
    }
    static func importLog(db: isolated Database, file: URL, assets: URL, device: String, me: String) throws -> (Int, Int) {
        let cursor = try db.query("SELECT offset,generation FROM sync_cursors WHERE device=?", [.text(device)]).first
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 256) ?? Data()
        let first = head.prefix(while: { $0 != 10 })
        let header = try? JSONDecoder().decode(JSONValue.self, from: first)
        let generation = header?["type"]?.string == "header" ? header?["row"]?["generation"]?.string ?? "" : ""
        var offset = UInt64(max(0, cursor?["offset"]?.integer ?? 0))
        if generation != (cursor?["generation"]?.string ?? "") || length < offset { offset = 0 }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        guard let end = data.lastIndex(of: 10) else { return (0, 0) }
        var imported = 0, conflicts = 0
        for bytes in data[...end].split(separator: 10) {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes)), let type = value["type"]?.string, let row = value["row"] else { continue }
            switch type {
            case "todo":
                guard let incoming = row.decode(Todo.self), !incoming.id.isEmpty, !incoming.updatedBy.isEmpty else { continue }
                let local = try Store.load(Todo.self, table: "todo", id: incoming.id, db: db)
                if local.map({ newer(incoming.updatedAt, incoming.updatedBy, $0.updatedAt, $0.updatedBy) }) ?? true {
                    try Store.write(incoming, dirty: false, db: db); imported += 1
                }
            case "doc":
                guard let incoming = row.decode(Doc.self), !incoming.id.isEmpty, !incoming.updatedBy.isEmpty else { continue }
                let local = try Store.load(Doc.self, table: "doc", id: incoming.id, db: db)
                guard local.map({ newer(incoming.updatedAt, incoming.updatedBy, $0.updatedAt, $0.updatedBy) }) ?? true else { continue }
                if var copy = local, incoming.baseAt != copy.updatedAt, copy.updatedBy == me, !copy.deleted, !incoming.deleted, copy.content != incoming.content {
                    copy.id = Workspace.newID(); copy.title = (copy.title.isEmpty ? "无标题" : copy.title) + "（冲突副本）"
                    if copy.kind == "daily" { copy.kind = "note" }
                    copy.day = nil; copy.createdAt = Workspace.now(); copy.updatedAt = copy.createdAt; copy.updatedBy = me; copy.baseAt = 0
                    try Store.write(copy, db: db); conflicts += 1
                }
                try Store.write(incoming, dirty: false, db: db); imported += 1
            case "inbox":
                guard let incoming = row.decode(InboxEntry.self), !incoming.id.isEmpty, !incoming.updatedBy.isEmpty else { continue }
                let local = try Store.load(InboxEntry.self, table: "inbox", id: incoming.id, db: db)
                if local.map({ newer(incoming.updatedAt, incoming.updatedBy, $0.updatedAt, $0.updatedBy) }) ?? true {
                    try Store.write(incoming, dirty: false, db: db); imported += 1
                }
            case "asset":
                guard let meta = row.decode(AssetMeta.self), safeID(meta.id) else { continue }
                let data = try? Data(contentsOf: assets.appendingPathComponent(meta.id))
                try db.execute("INSERT OR IGNORE INTO assets VALUES (?,?,?,?,0)", [.text(meta.id), .text(meta.mime), data.map(SQLValue.blob) ?? .null, .integer(meta.createdAt)])
            default: continue
            }
        }
        try db.execute("INSERT OR REPLACE INTO sync_cursors VALUES (?,?,?)", [.text(device), .integer(Int64(offset) + Int64(end) + 1), .text(generation)])
        return (imported, conflicts)
    }
    static func newer(_ time: Int64, _ device: String, _ oldTime: Int64, _ oldDevice: String) -> Bool {
        time > oldTime || time == oldTime && device > oldDevice
    }
}
