public import Foundation
import SQLite3

/// A single SQLite connection on the system libsqlite3. Not Sendable: each owner
/// confines its connection to one queue (History's writer queue, WordStore's
/// actor, the History window's main thread). Two connections, never one shared.
public final class Database {
    public enum Mode: Sendable { case readWrite, readOnly }

    let handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// Opens (creating if needed), sets WAL, `synchronous=NORMAL` (survives app
    /// crashes, consistent after power loss: #4), `foreign_keys=ON`, a busy timeout,
    /// then applies `migrations[user_version...]` in one transaction.
    ///
    /// `migrations` is append-only. Editing a shipped entry is a bug; add a new one.
    public init(at url: URL, mode: Mode, migrations: [String]) throws(DatabaseError) {
        var handle: OpaquePointer?
        let flags = switch mode {
        case .readWrite: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        case .readOnly: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        }
        let opened = sqlite3_open_v2(url.path(percentEncoded: false), &handle, flags, nil)
        self.handle = handle
        guard opened == SQLITE_OK else { throw error(opened) }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        guard mode == .readWrite else { return }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")

        // Read the version under the write lock, so two processes opening one file migrate once.
        try exec("BEGIN IMMEDIATE")
        do {
            let applied = Int(try query("PRAGMA user_version").first?.int(0) ?? 0)
            for migration in migrations[min(applied, migrations.count)...] { try exec(migration) }
            if applied < migrations.count { try exec("PRAGMA user_version = \(migrations.count)") }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    /// Runs `body` in BEGIN IMMEDIATE ... COMMIT; rolls back on throw.
    public func transaction<T>(_ body: (Database) throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body(self)
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func execute(_ sql: String, _ bindings: [SQLValue] = []) throws(DatabaseError) {
        _ = try run(sql, bindings)
    }

    /// Prepared statements are cached by SQL text for the life of the connection.
    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws(DatabaseError) -> [Row] {
        try run(sql, bindings)
    }

    /// Rows changed by the last statement (idempotent writes check this).
    public var changes: Int { Int(sqlite3_changes(handle)) }

    /// `PRAGMA data_version`: changes when ANOTHER connection commits.
    public var dataVersion: Int { Int((try? query("PRAGMA data_version").first?.int(0)) ?? 0) }

    private func run(_ sql: String, _ bindings: [SQLValue]) throws(DatabaseError) -> [Row] {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            let bound = switch value {
            case .null: sqlite3_bind_null(statement, position)
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .double(let v): sqlite3_bind_double(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, transient)
            case .blob(let v): v.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) }
            }
            guard bound == SQLITE_OK else { throw error(bound) }
        }
        var rows: [Row] = []
        let columns = sqlite3_column_count(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw error(step) }
            rows.append(Row(values: (0..<columns).map { column(statement, $0) }))
        }
    }

    private func prepared(_ sql: String) throws(DatabaseError) -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw error(prepared) }
        statements[sql] = statement
        return statement
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: .text(sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "")
        case SQLITE_BLOB:
            .blob(sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, index))) } ?? Data())
        default: .null
        }
    }

    /// Uncached, for multi-statement SQL (migrations) and transaction control.
    private func exec(_ sql: String) throws(DatabaseError) {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw error(result) }
    }

    private func error(_ code: Int32) -> DatabaseError {
        DatabaseError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open")
    }
}

/// SQLite copies bound text and blobs before the call returns.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public struct Row: Sendable, Hashable {
    let values: [SQLValue]
    public subscript(_ index: Int) -> SQLValue { values[index] }
    public func int(_ i: Int) -> Int64? { if case .int(let v) = values[i] { v } else { nil } }
    public func text(_ i: Int) -> String? { if case .text(let v) = values[i] { v } else { nil } }
}

public struct DatabaseError: Error, Sendable {
    public let code: Int32
    public let message: String
}
