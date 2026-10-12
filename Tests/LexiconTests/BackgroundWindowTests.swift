import Testing
import LexiconDomain
@testable import Transcription

// A background retry of a long Dictation must not hold the Neural Engine for its
// whole job ahead of a live fn-up (#117). The retry is chunked: each window is its
// own job on the model's queue, and a live window goes ahead of every queued
// background one. Through SpeechEngine, with a fake windowed model whose window
// decodes wait at a gate the test opens one at a time. The test decides which decode
// runs next, so the order it records is the order the queue gave, not the clock's.

/// The grid the criterion names: windows of 1_000 samples, 200 shared with the next.
private let windowGrid = WindowGrid(window: 1_000, overlap: 200)

/// One window decode as it started: its priority, where its window starts, and how
/// many samples it covers.
private struct WindowDecode: Sendable {
    let priority: LocalPriority
    let start: Int
    let samples: Int
}

/// A model that reads long audio in `windowGrid`'s windows, the way the real one does:
/// each window decode is its own job on the model's queue. A decode announces itself on
/// `entered` and then waits at the gate until the test releases it, so only one decode
/// is ever waiting there.
private actor WindowedGateModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    nonisolated let jobs = LocalJobQueue()
    /// Each window decode as it starts, in the order the queue ran them.
    nonisolated let entered: AsyncStream<WindowDecode>
    private nonisolated let enteredSink: AsyncStream<WindowDecode>.Continuation
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var isResident = true

    init() {
        let (stream, sink) = AsyncStream<WindowDecode>.makeStream()
        entered = stream
        enteredSink = sink
    }

    // Always resident: these tests are about the queue, not the model's load.
    func load() {}
    func unload() {}

    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WindowedSession<String>(grid: windowGrid, decode: { samples, start in
            try await self.jobs.run(priority) { try await self.decodeWindow(samples, start: start, priority: priority) }
        }, join: { windows in windows.joined(separator: " ") })
    }

    // Throws like a real window decode, so the job matches what the queue runs for a real model,
    // which skips a window whose Dictation was cancelled while it waited its turn.
    private func decodeWindow(_ samples: [Int16], start: Int, priority: LocalPriority) async throws -> String {
        try Task.checkCancellation()
        enteredSink.yield(WindowDecode(priority: priority, start: start, samples: samples.count))
        // The yield and the hold run in one turn of this actor, so `release()` always
        // finds the decode it was called for.
        await withCheckedContinuation { held.append($0) }
        return "\(priority == .live ? "live" : "background")-\(start)"
    }

    /// Lets the oldest held decode finish. False when none is waiting.
    func release() -> Bool {
        guard !held.isEmpty else { return false }
        held.removeFirst().resume()
        return true
    }

    /// No more decodes will be reported on `entered`.
    nonisolated func closeEntries() { enteredSink.finish() }
}

/// A cloud link whose network never changes: the process-wide NWPathMonitor would
/// re-arm the idle unload whenever the Mac's network moved mid-test.
private func noNetworkChanges(_ clock: TestClock) -> CloudLink {
    ScriptedCloud(clock: clock, script: []).link
}

@Test(.timeLimit(.minutes(1))) func aLiveDictationGoesAheadOfTheRestOfABackgroundRetry() async throws {
    let model = WindowedGateModel()
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: .defaults, access: nil, terms: [])
    // 8_000 samples with windows every 800 (the stride): starts 0 through 7_200, ten windows.
    let longClip = AudioClip(samples: syntheticSamples(count: 8_000))
    let shortClip = AudioClip(samples: syntheticSamples(count: 500))

    let retry = Task { await engine.transcribe(longClip, plan: plan, priority: .background) }
    var decodes = model.entered.makeAsyncIterator()
    // The retry's first window is running, held at the gate.
    let running = try #require(await decodes.next())
    #expect(running.priority == .background)

    // Jake's live Dictation: its audio is in, and fn-up finishes it.
    let (feed, input) = AudioFeed.makeStream()
    input.yield(PCMChunk(index: 0, samples: shortClip.samples))
    input.finish()
    // The attempt is non-copyable, so it is begun and finished in the same task.
    let live = Task { await engine.begin(feed: feed, plan: plan).finish(shortClip) }
    await model.jobs.untilWaiting(atLeast: 1)  // the live window waits behind the running retry window

    // The running window ends; the live window's turn comes before the retry's next window.
    #expect(await model.release())

    // Both tasks finish only after every decode they started has been released, so
    // closing the stream then ends the loop below without leaving a decode held.
    let done = Task {
        _ = await retry.value
        _ = await live.value
        model.closeEntries()
    }
    var order = [running]
    while let decode = await decodes.next() {
        order.append(decode)
        #expect(await model.release())
    }
    let liveOutcome = await live.value
    let retried = await retry.value
    await done.value

    // The live window is the very next decode after the window that was running.
    let liveAt = try #require(order.firstIndex { $0.priority == .live })
    #expect(liveAt == 1, "the live window should be the very next decode after the running retry window")
    // Background audio decoded before the live window: at most one window of it.
    let retryAhead = order[..<liveAt].reduce(0) { $0 + $1.samples }
    #expect(retryAhead <= windowGrid.window, "the retry decoded \(retryAhead) samples before the live window; one window is \(windowGrid.window)")

    guard case .text(let liveText) = liveOutcome else {
        Issue.record("live: expected text, got \(liveOutcome)")
        return
    }
    #expect(liveText.text == "live-0")
    guard case .text(let retriedText) = retried else {
        Issue.record("retry: expected text, got \(retried)")
        return
    }
    // Every window in grid order, joined.
    let starts = Array(stride(from: 0, through: 7_200, by: 800))
    #expect(retriedText.text == starts.map { "background-\($0)" }.joined(separator: " "))
}

@Test(.timeLimit(.minutes(1))) func aCancelledLiveDictationDecodesNothingWhenItsTurnComes() async throws {
    let model = WindowedGateModel()
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: .defaults, access: nil, terms: [])
    let longClip = AudioClip(samples: syntheticSamples(count: 8_000))

    let retry = Task { await engine.transcribe(longClip, plan: plan, priority: .background) }
    var decodes = model.entered.makeAsyncIterator()
    let running = try #require(await decodes.next())
    #expect(running.priority == .background)

    // Jake talks past one full window while the retry's window is running. That window
    // is decoded as soon as it is captured, so its decode queues behind the running one.
    let (feed, input) = AudioFeed.makeStream()
    input.yield(PCMChunk(index: 0, samples: syntheticSamples(count: windowGrid.window)))
    let attempt = await engine.begin(feed: feed, plan: plan)
    await model.jobs.untilWaiting(atLeast: 1)  // the live window queues behind the running retry window

    attempt.cancel()
    input.finish()
    // The running retry window ends; the cancelled live window's turn comes next.
    #expect(await model.release())

    let done = Task {
        _ = await retry.value
        model.closeEntries()
    }
    var order = [running]
    while let decode = await decodes.next() {
        order.append(decode)
        #expect(await model.release())
    }
    _ = await retry.value
    await done.value

    #expect(order.filter { $0.priority == .live }.isEmpty, "a cancelled live window was decoded after its cancel")
}
