public import Foundation
import SQLite3

/// A single SQLite connection on the system libsqlite3. Not Sendable: each owner
/// confines its connection to one queue (History's writer queue, WordStore's
/// actor, the History window's main thread). Two connections, never one shared.
public final class Database {
    public enum Mode: Sendable { case readWrite, readOnly }

    let handle: OpaquePointer?

    /// Opens (creating if needed), sets WAL, `synchronous=NORMAL` (survives app
    /// crashes, consistent after power loss: #4), `foreign_keys=ON`, a busy timeout,
    /// then applies `migrations[user_version...]` in one transaction.
    ///
    /// `migrations` is append-only. Editing a shipped entry is a bug; add a new one.
    public init(at url: URL, mode: Mode, migrations: [String]) throws(DatabaseError) {
        fatalError("not implemented")
    }

    /// Runs `body` in BEGIN IMMEDIATE ... COMMIT; rolls back on throw.
    public func transaction<T>(_ body: (Database) throws -> T) throws -> T {
        fatalError("not implemented")
    }

    public func execute(_ sql: String, _ bindings: [SQLValue] = []) throws(DatabaseError) {
        fatalError("not implemented")
    }

    /// Prepared statements are cached by SQL text for the life of the connection.
    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws(DatabaseError) -> [Row] {
        fatalError("not implemented")
    }

    /// Rows changed by the last statement (idempotent writes check this).
    public var changes: Int { fatalError("not implemented") }

    /// `PRAGMA data_version`: changes when ANOTHER connection commits.
    public var dataVersion: Int { fatalError("not implemented") }
}

public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public struct Row: Sendable {
    let values: [SQLValue]
    public subscript(_ index: Int) -> SQLValue { values[index] }
    public func int(_ i: Int) -> Int64? { if case .int(let v) = values[i] { v } else { nil } }
    public func text(_ i: Int) -> String? { if case .text(let v) = values[i] { v } else { nil } }
}

public struct DatabaseError: Error, Sendable {
    public let code: Int32
    public let message: String
}
