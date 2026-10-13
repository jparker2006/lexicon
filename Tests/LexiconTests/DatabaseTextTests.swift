import Foundation
import Testing
@testable import History
@testable import SQLiteKit
import AudioCapture
import LexiconDomain

// Text with a U+0000 in it comes back whole from SQLite. Database binds and reads
// text as C strings, so a NUL used to end the stored value early.

@Test func aNulInDictationTextIsStoredWhole() async throws {
    let store = try HistoryStore(paths: AppPaths.temporary())
    let value = "a\u{0}b\u{0}"
    let id = DictationID()
    try Data([0, 1]).write(to: store.audioURL(for: id))
    let app = AppContext(bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)
    let audio = AudioSummary(duration: .milliseconds(1_200), startGap: .milliseconds(40), deviceName: "Mic",
                             storage: .onDisk, gaps: [])
    // The events path(to: .ready) drives a fresh row through.
    store.record(.began(id, origin: .live, purpose: .type, at: Date(timeIntervalSince1970: 1_800_000_000), app: app))
    store.record(.audioEnded(id, audio))
    store.record(.textReady(id, TextVersions(model: value, cleaned: value), cleanup: .rulesOnly(.off),
                            model: .local(.parakeetUnified), typing: true))
    await store.flush()
    let row = try #require(await store.dictation(id))
    #expect(row.versions?.model == value)
    #expect(row.versions?.cleaned == value)
    #expect(row.finalText == value)
}

@Test(arguments: ["a\u{0}b\u{0}", "plain text", "", "café 日本", "café \u{0} 日本"])
func aTextColumnReadsBackWhatWasWritten(_ value: String) throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "lexicon-db-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try Database(at: dir.appending(path: "text.sqlite", directoryHint: .notDirectory), mode: .readWrite,
                          migrations: ["CREATE TABLE t(v TEXT)"])
    try db.execute("INSERT INTO t VALUES (?)", [.text(value)])
    let read = try db.query("SELECT v FROM t").first?.text(0)
    #expect(read == value)
}
