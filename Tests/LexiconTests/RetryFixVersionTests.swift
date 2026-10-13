import Foundation
import Testing
@testable import LexiconCore
import AudioCapture
import History
import LexiconDomain
import Transcription
@testable import LexiconUI

// A Fix made on a Dictation survives a Retry, and the version the Retry replaced
// keeps the text the Fix was made on (#213). Headless: the real Conductor on a
// synthetic WAV, as RetryTests does. Fixes go in through History's write API.

/// Hears `texts` in order, then the last one again.
private actor ChangingTranscriber: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private var texts: [String?]

    init(_ texts: [String?]) { self.texts = texts }

    var isResident: Bool { true }
    func load() {}
    func unload() {}
    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { clip in try await self.transcribe(clip, terms: terms, priority: priority) }
    }

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) throws -> String {
        let text = texts.count > 1 ? texts.removeFirst() : texts[0]
        guard let text else { throw LocalModelNotInstalled(model) }
        return text
    }
}

private func system(at paths: AppPaths, hearing texts: String?...) throws -> HeadlessSystem {
    try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                            local: ChangingTranscriber(texts), clock: TestClock())
}

private func wav() throws -> URL {
    try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: try scratchDirectory())
}

/// A correction that turns `before` into `after` in the Dictation's final text.
private func fixMade(on id: DictationID, _ before: String, _ after: String) -> Fix {
    Fix(dictation: id, kind: .respeak, source: .respeak, before: before, after: after,
        verdict: .proposed, at: Date(timeIntervalSince1970: 1_800_000_100))
}

@MainActor @Test func aFixMadeBeforeARetryStillAppliesAfterIt() async throws {
    let paths = AppPaths.temporary()
    let system = try system(at: paths, hearing: "ship it to super base", "ship it to the server", "ship it to super base")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    let heard = try #require(first.versions?.cleaned)
    // Without this, a Cleanup that dropped "super base" would make every Fix check below pass for nothing.
    try #require(heard.contains("super base"))
    system.history.record(.fixRecorded(fixMade(on: first.id, "super base", "Supabase")))
    await system.history.flush()

    // The Retry's words have no "super base", so the Fix has nothing to change in them.
    // The version it replaced keeps the text the Fix was made on, and the fixed final.
    let server = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()
    let afterServer = try #require(HistoryReader(paths: paths).detail(first.id))
    #expect(afterServer.row.finalText == server.versions?.cleaned)
    #expect(afterServer.earlier.first?.cleaned == heard)
    #expect(afterServer.earlier.first?.final == heard.replacing("super base", with: "Supabase"))

    // The Fix is still on the row: a Retry that hears "super base" again gets it applied.
    let again = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()
    let expected = try #require(again.versions?.cleaned).replacing("super base", with: "Supabase")
    let afterAgain = try #require(HistoryReader(paths: paths).detail(first.id))
    #expect(afterAgain.row.finalText == expected)
}

@MainActor @Test func aRetryThatStillHearsTheFixsWordsAppliesTheFixAndKeepsTheOldFinal() async throws {
    let paths = AppPaths.temporary()
    let system = try system(at: paths, hearing: "ship it to super base", "send it to super base now")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    let heard = try #require(first.versions?.cleaned)
    try #require(heard.contains("super base"))
    system.history.record(.fixRecorded(fixMade(on: first.id, "super base", "Supabase")))
    await system.history.flush()

    let retried = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()
    let heardNow = try #require(retried.versions?.cleaned)
    let detail = try #require(HistoryReader(paths: paths).detail(first.id))

    #expect(detail.row.finalText == heardNow.replacing("super base", with: "Supabase"))
    #expect(detail.earlier.first?.cleaned == heard)
    #expect(detail.earlier.first?.final == heard.replacing("super base", with: "Supabase"))
}

@MainActor @Test func showVersionsShowsTheTextAFixWasMadeOnUnderTheEarlierVersion() async throws {
    let paths = AppPaths.temporary()
    let system = try system(at: paths, hearing: "ship it to super base", "ship it to the server")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    let heard = try #require(first.versions?.cleaned)
    try #require(heard.contains("super base"))
    system.history.record(.fixRecorded(fixMade(on: first.id, "super base", "Supabase")))
    await system.history.flush()
    _ = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()

    let detail = try #require(HistoryReader(paths: paths).detail(first.id))
    let shown = HistoryText.versions(detail)
    #expect(shown.contains { $0.label.contains("Replaced") })
    #expect(shown.map(\.text).contains(heard))
    #expect(shown.map(\.text).contains(heard.replacing("super base", with: "Supabase")))
}
