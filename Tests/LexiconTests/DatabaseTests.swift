import Foundation
import Testing
@testable import SQLiteKit

// Database.transaction on a real connection in a throwaway folder: no mic, no app,
// no network. A failed rollback reopens the connection, and the body's error still wins.

private let schema = ["CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)"]

/// The error a transaction body throws. Equatable, so #expect(throws:) checks it is the same one.
private struct Boom: Error, Equatable { let tag: String }

private func openDatabase(in folder: URL, migrations: [String] = schema) throws -> Database {
    try Database(at: folder.appending(path: "lexicon.sqlite"), mode: .readWrite, migrations: migrations)
}

private func insertRow(_ db: Database, _ value: String) throws {
    try db.execute("INSERT INTO t(v) VALUES (?)", [.text(value)])
}

/// Writes `value`, then throws `error`: the transaction must roll that write back.
private func insertThenThrow(_ db: Database, _ value: String, _ error: Boom) throws {
    try insertRow(db, value)
    throw error
}

private func storedValues(_ db: Database) throws -> [String] {
    try db.query("SELECT v FROM t ORDER BY id").compactMap { $0.text(0) }
}

/// Temp tables belong to one connection, so this one is gone exactly when the connection reopened.
private func tempMarkerExists(_ db: Database) throws -> Bool {
    try !db.query("SELECT name FROM sqlite_temp_master WHERE name = 'marker'").isEmpty
}

@Test func aFailingRollbackRethrowsTheBodyErrorAndDropsItsWrites() throws {
    let folder = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let db = try openDatabase(in: folder)
    try db.transaction { try insertRow($0, "kept") }
    db.rollbackStatement = "ROLLBACK TO nosuchsavepoint"

    let boom = Boom(tag: "body")
    #expect(throws: boom) { try db.transaction { try insertThenThrow($0, "lost", boom) } }
    try db.transaction { try insertRow($0, "after") }
    #expect(try storedValues(db) == ["kept", "after"])
}

@Test func aDefaultRollbackRollsBackWithoutReopeningTheConnection() throws {
    let folder = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let db = try openDatabase(in: folder)
    try db.execute("CREATE TEMP TABLE marker(x)")
    try db.transaction { try insertRow($0, "kept") }

    let boom = Boom(tag: "body")
    #expect(throws: boom) { try db.transaction { try insertThenThrow($0, "lost", boom) } }
    try db.transaction { try insertRow($0, "after") }
    #expect(try storedValues(db) == ["kept", "after"])
    #expect(try tempMarkerExists(db))
}

@Test func aReopenKeepsCommittedRowsAndPragmasWithoutMigratingAgain() throws {
    let folder = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    // The last migration throws if it runs twice (no IF NOT EXISTS) and counts its runs.
    let migrations = schema + ["CREATE TABLE runs(n INTEGER)", "CREATE TABLE once(x); INSERT INTO runs(n) VALUES (1)"]
    let db = try openDatabase(in: folder, migrations: migrations)
    try db.transaction { try insertRow($0, "kept") }
    try db.execute("CREATE TEMP TABLE marker(x)")
    db.rollbackStatement = "ROLLBACK TO nosuchsavepoint"

    let boom = Boom(tag: "body")
    #expect(throws: boom) { try db.transaction { try insertThenThrow($0, "lost", boom) } }

    #expect(try storedValues(db) == ["kept"])
    #expect(try db.query("PRAGMA foreign_keys").first?.int(0) == 1)
    #expect(try db.query("PRAGMA journal_mode").first?.text(0) == "wal")
    #expect(try tempMarkerExists(db) == false)
    #expect(try db.query("SELECT n FROM runs").compactMap { $0.int(0) } == [1])
}

@Test func aReopenThatFailsRethrowsTheBodyErrorAndTheNextTransactionRetries() throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let folder = scratch.appending(path: "data")
    let parked = scratch.appending(path: "parked")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let db = try openDatabase(in: folder)
    try db.transaction { try insertRow($0, "kept") }
    db.rollbackStatement = "ROLLBACK TO nosuchsavepoint"

    // With the folder parked, the reopen cannot open the path and must fail.
    try FileManager.default.moveItem(at: folder, to: parked)
    let boom = Boom(tag: "body")
    #expect(throws: boom) { try db.transaction { try insertThenThrow($0, "lost", boom) } }
    #expect(throws: (any Error).self) { try db.transaction { try insertRow($0, "during") } }

    try FileManager.default.moveItem(at: parked, to: folder)
    try db.transaction { try insertRow($0, "after") }
    #expect(try storedValues(db) == ["kept", "after"])
}
