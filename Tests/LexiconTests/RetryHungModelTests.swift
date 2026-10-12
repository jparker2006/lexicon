import Foundation
import Testing
@testable import LexiconCore
import LexiconDomain
@testable import Transcription

// A Retry whose local model hangs. Headless: the real Conductor
// on a synthetic WAV, a local model whose first session answers and whose later
// sessions hang until the test releases them, and a fake clock. Each step waits on
// a stream event or on the clock's pending sleep; nothing waits on the wall clock.

/// The first session hears "kept text". Every later session hangs until `release`,
/// and each hang is announced on `hanging` when it begins.
private actor HangingTranscriber: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    /// One element for each session that starts to hang, in order.
    nonisolated let hanging: AsyncStream<Void>
    private let hangs: AsyncStream<Void>.Continuation
    /// Every session that reached the model, hung or not.
    private(set) var sessions = 0
    private var hung: [CheckedContinuation<String, Never>] = []

    init() {
        let (hanging, hangs) = AsyncStream<Void>.makeStream()
        self.hanging = hanging
        self.hangs = hangs
    }

    var isResident: Bool { true }
    func load() {}
    func unload() {}
    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { clip in await self.transcribe(clip, terms: terms, priority: priority) }
    }

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) async -> String {
        sessions += 1
        guard sessions > 1 else { return "kept text" }
        hangs.yield(())
        return await withCheckedContinuation { hung.append($0) }
    }

    /// Answers every hung session with `text`. A session whose local side has
    /// already given up ignores its answer.
    func release(_ text: String) {
        for waiter in hung { waiter.resume(returning: text) }
        hung = []
    }
}

private func wav() throws -> URL {
    try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: try scratchDirectory())
}

/// A cloud link whose network never changes: the process-wide NWPathMonitor
/// would re-arm the idle unload whenever the Mac's network moved mid-test.
private func noNetworkChanges(_ clock: TestClock) -> CloudLink {
    ScriptedCloud(clock: clock, script: []).link
}

@Test(.timeLimit(.minutes(1))) func aRetryWhoseModelHangsEndsAtTheLimitAndFreesTheDictation() async throws {
    let clock = TestClock()
    let model = HangingTranscriber()
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                                         local: model, cloud: noNetworkChanges(clock), clock: clock)
    // However the test ends, no hung session is left suspended.
    defer { Task { await model.release("released") } }

    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    #expect(first.status == .inserted)
    await system.history.flush()
    let before = try #require(await system.history.dictation(first.id))

    // The Retry's model hangs. The limit is 30 s plus a quarter of the 1 s clip: 30.25 s.
    var hanging = model.hanging.makeAsyncIterator()
    let retrying = Task { await system.conductor.retry(first.id, with: nil) }
    _ = await hanging.next()
    #expect(await system.conductor.inFlight[first.id] != nil)  // still in flight while the model hangs

    // A sleep that ends at the limit is the Retry's limit. Without one this wait only ends
    // when the time limit cancels the test, and then the test fails here, not on a hang.
    await clock.waitForSleep(endingAt: clock.now.offset + .milliseconds(30_250))
    guard !Task.isCancelled else {
        Issue.record("no sleep ends at 30.25 s: the Retry of a hung model has no limit")
        return
    }
    await clock.advance(by: .milliseconds(30_250))
    let retried = await retrying.value
    await system.history.flush()

    #expect(retried.versions == nil)
    let after = try #require(await system.history.dictation(first.id))
    #expect(after.finalText == before.finalText)
    #expect(after.status == before.status)
    #expect(await system.conductor.inFlight[first.id] == nil)

    // Out of `inFlight`, a second Retry reaches the model again and is not refused.
    let again = Task { await system.conductor.retry(first.id, with: nil) }
    _ = await hanging.next()
    #expect(await model.sessions == 3)  // the first Dictation, the timed-out Retry, this Retry
    await model.release("second try")
    let second = await again.value
    await system.history.flush()

    #expect(second.versions?.model == "second try")
    #expect(await system.history.dictation(first.id)?.finalText == second.versions?.cleaned)
}
