import Foundation
import Testing
@testable import History
import LexiconDomain

// Earlier versions (#213): what a Retry replaces stays readable until its
// Dictation is deleted, and a History file from before the change opens and
// reads as it did. Events go straight into History, where a Retry's text lands.

private let app = AppContext(bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: nil, deviceName: "Mic", storage: .onDisk, gaps: [])
private let parakeet = SpeechModel.local(.parakeetUnified)
private let receipt = InsertionReceipt(appBundleID: app.bundleID, fieldFingerprint: nil, caretAfter: nil,
                                       contextBefore: "", contextAfter: "", insertedAt: start)

private func makeStore() throws -> (HistoryStore, AppPaths) {
    let paths = AppPaths.temporary()
    return (try HistoryStore(paths: paths), paths)
}

/// A live Dictation recorded through to inserted, as the Conductor records it.
private func dictate(_ store: HistoryStore, _ text: String) -> DictationID {
    let id = DictationID()
    store.record(.began(id, origin: .live, purpose: .type, at: start, app: app))
    store.record(.audioEnded(id, audio))
    store.record(.textReady(id, TextVersions(model: text, cleaned: text), cleanup: .rulesOnly(.off), model: parakeet, typing: true))
    store.record(.delivered(id, receipt, lag: .milliseconds(420)))
    return id
}

/// A Retry that got text. Its version is minted once per Retry, so a replay is the same event.
private func retry(_ store: HistoryStore, _ id: DictationID, _ text: String, version: UUID = UUID()) {
    store.record(.retried(id, TextVersions(model: text, cleaned: text), cleanup: CleanupOutcome.rulesOnly(.off),
                          model: parakeet, version: version))
}

/// How many cells of any table in history.sqlite hold one of `texts`.
private func cellsHolding(_ texts: [String], in store: HistoryStore) async throws -> Int64 {
    try await store.read { db -> Int64 in
        var found: Int64 = 0
        for table in try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap({ $0.text(0) }) {
            for column in try db.query("PRAGMA table_info(\"\(table)\")").compactMap({ $0.text(1) }) {
                for text in texts {
                    found += try db.query("SELECT count(*) FROM \"\(table)\" WHERE instr(CAST(\"\(column)\" AS TEXT), ?) > 0",
                                          [.text(text)]).first?.int(0) ?? 0
                }
            }
        }
        return found
    }
}

private let oldModel = "wire the auth callback into super base"
private let oldCleaned = "Wire the auth callback into Supabase."
private let oldFinal = "Wire the OAuth callback into Supabase."

/// A History file as the build before earlier versions left it: migrations 0 and 1
/// and one inserted Dictation. Written by the system's sqlite3, the one way a test
/// runs a child process (runChild); LexiconTests does not depend on SQLiteKit.
private func writeOldHistory(at paths: AppPaths, id: DictationID) async throws {
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    let cleanup = try CleanupOutcome.rulesOnly(.off).column()
    let oldMigrations = HistorySchema.migrations.prefix(2)
    let script = oldMigrations.joined(separator: "\n") + """
        INSERT INTO dictation (id, started_at, origin, purpose, status, model_text, cleaned_text, final_text,
                               cleanup, model, lag_ms, audio_storage, app_bundle_id, app_title)
        VALUES ('\(id)', \(start.unixMs), 'live', 'type', 'inserted', '\(oldModel)', '\(oldCleaned)', '\(oldFinal)',
                '\(cleanup)', '\(parakeet.id)', 480, 'onDisk', 'com.example.editor', 'Editor');
        PRAGMA user_version = \(oldMigrations.count);
        """
    let file = paths.root.appending(path: "history.sqlite")
    let child = try await runChild(URL(filePath: "/usr/bin/sqlite3"), [file.path(percentEncoded: false), script])
    try #require(child.status == 0 && child.output.isEmpty, "sqlite3 wrote the old file: \(child.output)")
}

// MARK: - Deleting

@MainActor @Test func deletingADictationTakesItsEarlierVersionsAndTheirText() async throws {
    let (store, paths) = try makeStore()
    let id = dictate(store, "First words.")
    retry(store, id, "Second words.")
    retry(store, id, "Third words.")
    await store.flush()
    let kept = try #require(HistoryReader(paths: paths).detail(id))
    #expect(kept.earlier.map(\.final) == ["Second words.", "First words."])

    store.record(.deleted(id))
    await store.flush()
    #expect(HistoryReader(paths: paths).detail(id) == nil)
    let versions = try await store.read { db in try db.query("SELECT count(*) FROM earlier_version").first?.int(0) }
    #expect(versions == 0)
    #expect(try await cellsHolding(["First words.", "Second words.", "Third words."], in: store) == 0)
}

// MARK: - Replays

@MainActor @Test func replayingTheSameRetryKeepsOneEarlierVersion() async throws {
    let (store, paths) = try makeStore()
    let id = dictate(store, "First words.")
    let version = UUID()
    retry(store, id, "Second words.", version: version)
    await store.flush()
    retry(store, id, "Second words.", version: version)
    retry(store, id, "Second words.", version: version)
    await store.flush()

    let detail = try #require(HistoryReader(paths: paths).detail(id))
    #expect(detail.earlier.map(\.final) == ["First words."])
}

// MARK: - Older files

@MainActor @Test func anOlderHistoryFileOpensUnchangedAndKeepsItsTextWhenRetried() async throws {
    let paths = AppPaths.temporary()
    let id = DictationID()
    try await writeOldHistory(at: paths, id: id)

    let store = try HistoryStore(paths: paths)
    let reader = HistoryReader(paths: paths)
    let before = try #require(reader.detail(id))
    #expect(before.row.status == .inserted)
    #expect(before.row.finalText == oldFinal)
    #expect(before.versions == TextVersions(model: oldModel, cleaned: oldCleaned))
    #expect(before.earlier.isEmpty)
    let section = try #require(reader.sections(matching: nil, rows: 10).first)
    #expect(reader.rows(in: section, offsets: 0..<section.count).compactMap(\.finalText) == [oldFinal])

    retry(store, id, "New words.")
    await store.flush()
    let after = try #require(HistoryReader(paths: paths).detail(id))
    #expect(after.earlier.map(\.final) == [oldFinal])
    #expect(after.earlier.map(\.cleaned) == [oldCleaned])
    #expect(after.earlier.first?.model == parakeet)
    #expect(after.row.finalText == "New words.")
}

// MARK: - A failed Dictation

@MainActor @Test func aRetryThatGetsTextForAFailedDictationKeepsNoEarlierVersion() async throws {
    let (store, paths) = try makeStore()
    let id = DictationID()
    store.record(.began(id, origin: .live, purpose: .type, at: start, app: app))
    store.record(.audioEnded(id, audio))
    store.record(.failed(id, reason: "silent"))
    await store.flush()

    retry(store, id, "Recovered words.")
    await store.flush()

    let detail = try #require(HistoryReader(paths: paths).detail(id))
    #expect(detail.earlier.isEmpty)
    #expect(detail.row.status == .notInserted)
    #expect(detail.versions == TextVersions(model: "Recovered words.", cleaned: "Recovered words."))
}
