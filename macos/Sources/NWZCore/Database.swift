import CSQLite
import Foundation

public enum SQLValue: Sendable, Equatable {
    case null, integer(Int64), real(Double), text(String), blob(Data)

    public var string: String? { if case .text(let value) = self { value } else { nil } }
    public var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
}

public struct DatabaseError: Error, LocalizedError, Sendable {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { "数据库错误：\(message)" }
}

/// 每个库独占一个连接；事务闭包不能挂起，避免其他任务插入事务中途。
public actor Database {
    public struct Migration: Sendable {
        public let version: Int
        public let sql: String
        public init(version: Int, sql: String) { self.version = version; self.sql = sql }
    }

    private let connection: Connection

    public init(path: String = ":memory:", migrations: [Migration] = []) throws {
        let connection = try Connection(path: path)
        try connection.migrate(migrations)
        self.connection = connection
    }

    public func migrate(_ migrations: [Migration]) throws { try connection.migrate(migrations) }

    public func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        _ = try connection.query(sql, values)
    }

    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        try connection.query(sql, values)
    }

    public func transaction<T: Sendable>(_ body: @Sendable (isolated Database) throws -> T) throws -> T {
        try connection.script("BEGIN IMMEDIATE")
        do {
            let value = try body(self)
            try connection.script("COMMIT")
            return value
        } catch {
            try? connection.script("ROLLBACK")
            throw error
        }
    }
}

private final class Connection {
    let handle: OpaquePointer

    init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let pointer { sqlite3_close(pointer) }
            throw DatabaseError(code: result, message: message)
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try script("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA recursive_triggers = ON")
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func script(_ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw failure(result) }
    }

    func failure(_ code: Int32) -> DatabaseError {
        DatabaseError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    func migrate(_ migrations: [Database.Migration]) throws {
        guard migrations.enumerated().allSatisfy({ $0.element.version == $0.offset + 1 }) else {
            throw DatabaseError(code: SQLITE_MISUSE, message: "迁移版本必须从 1 连续递增")
        }
        try script("BEGIN IMMEDIATE")
        do {
            let current = try query("PRAGMA user_version", []).first?["user_version"]?.integer ?? 0
            if !migrations.isEmpty, current > migrations.count {
                throw DatabaseError(code: SQLITE_MISUSE, message: "数据库版本较新，请升级应用")
            }
            for migration in migrations where migration.version > current {
                try script(migration.sql)
                try script("PRAGMA user_version = \(migration.version)")
            }
            try script("COMMIT")
        } catch {
            try? script("ROLLBACK")
            throw error
        }
    }

    func query(_ sql: String, _ values: [SQLValue]) throws -> [[String: SQLValue]] {
        let statement = try Statement(connection: self, sql: sql, values: values)
        var rows: [[String: SQLValue]] = []
        while true {
            let result = sqlite3_step(statement.handle)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure(result) }
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement.handle) {
                row[String(cString: sqlite3_column_name(statement.handle, index))] = statement.value(at: index)
            }
            rows.append(row)
        }
    }
}

private final class Statement {
    let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(connection: Connection, sql: String, values: [SQLValue]) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_prepare_v2(connection.handle, sql, -1, &pointer, nil)
        guard result == SQLITE_OK, let pointer else { throw connection.failure(result) }
        handle = pointer
        do {
            guard sqlite3_bind_parameter_count(handle) == values.count else {
                throw DatabaseError(code: SQLITE_MISUSE, message: "SQL 参数数量不匹配")
            }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .null: result = sqlite3_bind_null(handle, index)
                case .integer(let value): result = sqlite3_bind_int64(handle, index, value)
                case .real(let value): result = sqlite3_bind_double(handle, index, value)
                case .text(let value):
                    result = value.withCString { sqlite3_bind_text(handle, index, $0, Int32(value.utf8.count), Self.transient) }
                case .blob(let value):
                    result = value.isEmpty ? sqlite3_bind_zeroblob(handle, index, 0) : value.withUnsafeBytes {
                        sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), Self.transient)
                    }
                }
                guard result == SQLITE_OK else { throw connection.failure(result) }
            }
        } catch {
            sqlite3_finalize(handle)
            throw error
        }
    }

    deinit { sqlite3_finalize(handle) }

    func value(at index: Int32) -> SQLValue {
        switch sqlite3_column_type(handle, index) {
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(handle, index))
        case SQLITE_FLOAT: .real(sqlite3_column_double(handle, index))
        case SQLITE_TEXT:
            .text(String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(handle, index), count: Int(sqlite3_column_bytes(handle, index))), as: UTF8.self))
        case SQLITE_BLOB:
            .blob(sqlite3_column_blob(handle, index).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(handle, index))) } ?? Data())
        default: .null
        }
    }
}
