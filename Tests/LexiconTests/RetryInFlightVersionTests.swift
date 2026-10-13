import Foundation
import Testing
@testable import LexiconCore
import History
import LexiconDomain
import Transcription

// A Retry refused because the Dictation is already being retried saves no earlier
// version (#213). Headless: the real Conductor on a synthetic WAV, a local model whose
// first session answers and whose later sessions hang until the test releases them,
// and a fake clock that never moves, so the hung Retry is still in flight.

/// The first session hears "kept text"; later ones hang until `release`, announced on `hanging`.
private actor HangingTranscriber: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    nonisolated let hanging: AsyncStream<Void>
    private let hangs: AsyncStream<Void>.Continuation
    private var sessions = 0
    private var hung: [CheckedContinuation<String, Never>] = []

    init() {
        (hanging, hangs) = AsyncStream<Void>.makeStream()
    }

    var isResident: Bool { true }
    func load() {}
    func unload() {}
    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { _ in await self.transcribe() }
    }

    private func transcribe() async -> String {
        sessions += 1
        guard sessions > 1 else { return "kept text" }
        hangs.yield(())
        return await withCheckedContinuation { hung.append($0) }
    }

    func release(_ text: String) {
        for waiter in hung { waiter.resume(returning: text) }
        hung = []
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func aRetryRefusedWhileTheDictationIsBeingRetriedSavesNoVersion() async throws {
    let paths = AppPaths.temporary()
    let clock = TestClock()
    let model = HangingTranscriber()
    let system = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults, local: model,
                                         cloud: ScriptedCloud(clock: clock, script: []).link, clock: clock)
    defer { Task { await model.release("released") } }
    let first = await system.conductor.dictate(file: try writeWAV(syntheticSamples(count: 16_000), rate: 16_000,
                                                                  in: try scratchDirectory()),
                                               pace: .asFastAsPossible)
    await system.history.flush()

    var hanging = model.hanging.makeAsyncIterator()
    let retrying = Task { await system.conductor.retry(first.id, with: nil) }
    _ = await hanging.next()  // the first Retry is in flight
    let refused = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()

    #expect(refused.status == nil && refused.versions == nil)
    #expect(try #require(HistoryReader(paths: paths).detail(first.id)).earlier.isEmpty)

    // The Retry in flight still lands, and saves the one version.
    await model.release("second try")
    _ = await retrying.value
    await system.history.flush()
    #expect(try #require(HistoryReader(paths: paths).detail(first.id)).earlier.count == 1)
}
