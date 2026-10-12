import Synchronization
import Testing
@testable import LexiconCore
import LexiconDomain
@testable import Transcription

// Long Dictations (#117), through `SpeechEngine.begin(feed:plan:)` with a feed the
// test controls and a fake windowed model on a small grid: no Neural Engine, no mic,
// no network, no wall clock. Every window decode is logged with where it started,
// how many samples it got, its first sample, and whether `attempt.finish` had been
// called, so a test can see which windows ran while Jake was still talking.

@Test(.timeLimit(.minutes(1))) func aLongDictationDecodesEachWindowWhileJakeTalks() async throws {
    let clock = TestClock()
    let fake = WindowedFake()
    let engine = SpeechEngine(local: fake, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: .defaults, access: nil, terms: [])
    let samples = clipSamples(count: 4_500)
    let (feed, input) = AudioFeed.makeStream()

    let attempt = await engine.begin(feed: feed, plan: plan)
    for chunk in chunks(of: samples, sizes: [100]) { input.yield(chunk) }

    // Still talking. Windows at 0 to 3_200 are whole by now (start + 1_000 <= 4_500);
    // the window at 4_000 is not, so it is the only one left for fn-up.
    await fake.waitForDecodes(of: [0, 800, 1_600, 2_400, 3_200])
    let beforeFnUp = fake.decodes

    input.finish()
    fake.markFnUp()
    let outcome = await attempt.finish(AudioClip(samples: samples))
    let decodes = fake.decodes

    #expect(beforeFnUp.map(\.start) == [0, 800, 1_600, 2_400, 3_200])
    #expect(decodes.map(\.start) == [0, 800, 1_600, 2_400, 3_200, 4_000])
    #expect(decodes.map(\.count) == [1_000, 1_000, 1_000, 1_000, 1_000, 500])
    #expect(decodes.allSatisfy { $0.first == sample(samples, at: $0.start) })
    // Fn-up's own work is the tail window alone; the complete windows were not decoded twice.
    #expect(decodes.filter(\.afterFnUp).map(\.start) == [4_000])
    #expect(spokenText(outcome) == "w0:1000 w800:1000 w1600:1000 w2400:1000 w3200:1000 w4000:500")
}

@Test(.timeLimit(.minutes(1))) func aShortDictationDecodesOnceAtFnUp() async throws {
    let clock = TestClock()
    let fake = WindowedFake()
    let engine = SpeechEngine(local: fake, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: .defaults, access: nil, terms: [])
    // Shorter than one window: no window is whole while Jake talks, so nothing can decode early.
    let samples = clipSamples(count: 600)
    let (feed, input) = AudioFeed.makeStream()

    let attempt = await engine.begin(feed: feed, plan: plan)
    for chunk in chunks(of: samples, sizes: [100]) { input.yield(chunk) }
    input.finish()

    fake.markFnUp()
    let outcome = await attempt.finish(AudioClip(samples: samples))

    #expect(fake.decodes == [Decode(start: 0, count: 600, first: sample(samples, at: 0), afterFnUp: true)])
    #expect(spokenText(outcome) == "w0:600")
}

@Test(.timeLimit(.minutes(1))) func aLiveDictationGivesTheSameWordsAsTheOneShotPath() async throws {
    let clock = TestClock()
    let fake = WindowedFake()
    let engine = SpeechEngine(local: fake, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: .defaults, access: nil, terms: [])
    let samples = clipSamples(count: 4_500)
    let clip = AudioClip(samples: samples)

    // Uneven chunks, so windows start and end inside a chunk rather than on its edge.
    let (feed, input) = AudioFeed.makeStream()
    let attempt = await engine.begin(feed: feed, plan: plan)
    for chunk in chunks(of: samples, sizes: [70, 130, 250]) { input.yield(chunk) }
    input.finish()
    let live = await attempt.finish(clip)

    // The whole clip through the one-shot path, with the same fake.
    let oneShot = await engine.transcribe(clip, plan: plan)

    #expect(spokenText(oneShot) != nil)
    #expect(spokenText(live) == spokenText(oneShot))
}

@Test(.timeLimit(.minutes(1))) func aWindowThatFailsWhileJakeTalksIsDecodedAgainFromTheClipAtFnUp() async throws {
    let clock = TestClock()
    let fake = WindowedFake(failingFirst: true)
    let engine = SpeechEngine(local: fake, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: .defaults, access: nil, terms: [])
    let samples = clipSamples(count: 1_800)
    let (feed, input) = AudioFeed.makeStream()

    let attempt = await engine.begin(feed: feed, plan: plan)
    for chunk in chunks(of: samples, sizes: [100]) { input.yield(chunk) }
    // The window at 0 is whole, and its decode fails once (a model hiccup while Jake talks).
    await fake.waitForDecodes(of: [0])
    input.finish()
    fake.markFnUp()
    let outcome = await attempt.finish(AudioClip(samples: samples))

    // The clip is whole at fn-up, so a failed window is one more decode from it, not a lost Dictation.
    #expect(spokenText(outcome) == "w0:1000 w800:1000")
}

@Test(.timeLimit(.minutes(1))) func theConductorFeedsALiveDictationsAudioToTheLocalModelAsItIsCaptured() async throws {
    let fake = WindowedFake()
    let clock = TestClock()
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                                         local: fake, cloud: noNetworkChanges(clock), clock: clock)
    let wav = try writeWAV(clipSamples(count: 4_500), rate: 16_000, in: try scratchDirectory())

    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)

    // The capture's own feed reaches the session, every sample of it: the path a long
    // live Dictation takes to have its windows decoded before fn-up.
    let total = try #require(fake.finishedClip)
    await fake.waitForAppended(total)
    #expect(fake.appended == total)
    let expected = WindowedFake.grid.starts(total: total)
        .map { "w\($0):\(min(WindowedFake.grid.window, total - $0))" }.joined(separator: " ")
    #expect(result.attempts.first?.text == expected)
}

// MARK: Helpers

/// One window's decode, as the fake saw it.
private struct Decode: Equatable, Sendable {
    let start: Int
    let count: Int
    let first: Int16?
    /// Decoded after `attempt.finish` was called, so on fn-up's path to the text.
    let afterFnUp: Bool
}

/// A windowed model on a 1_000-sample grid overlapping by 200. Each window decodes to
/// "w<start>:<count>", and a clip's text is its windows joined by spaces.
private final class WindowedFake: LocalTranscriber, Sendable {
    static let grid = WindowGrid(window: 1_000, overlap: 200)
    /// Each wait gives up after this many yields. A decode runs on another task, so
    /// every yield gives it a turn; the budget only ends a wait that nothing answers,
    /// so the assertion after it reports what decoded instead of the test running to
    /// its time limit. It counts yields, not seconds, so a slow Mac only waits longer.
    static let yieldBudget = 2_000_000

    let model = LocalModel.parakeetUnified
    private let state: Mutex<State>

    private struct State: Sendable {
        var decodes: [Decode] = []
        var fnUp = false
        /// Samples the session was handed while Jake talked, and the clip it got at fn-up.
        var appended = 0
        var finishedClip: Int?
        /// The next decode throws, as a model call can.
        var failNext = false
    }

    init(failingFirst: Bool = false) {
        state = Mutex(State(failNext: failingFirst))
    }

    var isResident: Bool { get async { true } }
    func load() async {}
    func unload() async {}

    func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        Counted(fake: self, base: WindowedSession<String>(grid: Self.grid, decode: { samples, start in
            try self.record(samples: samples, start: start)
            return "w\(start):\(samples.count)"
        }, join: { windows in windows.joined(separator: " ") }))
    }

    var decodes: [Decode] { state.withLock { $0.decodes } }
    var appended: Int { state.withLock { $0.appended } }
    var finishedClip: Int? { state.withLock { $0.finishedClip } }

    /// The real session, with what it was handed counted.
    private final class Counted: LocalSession {
        let fake: WindowedFake
        let base: any LocalSession
        init(fake: WindowedFake, base: any LocalSession) {
            self.fake = fake
            self.base = base
        }

        func append(_ samples: [Int16]) {
            fake.state.withLock { $0.appended += samples.count }
            base.append(samples)
        }

        func finish(_ clip: AudioClip) async throws -> String {
            fake.state.withLock { $0.finishedClip = clip.samples.count }
            return try await base.finish(clip)
        }

        func cancel() { base.cancel() }
    }

    /// Yields until the session has been handed `count` samples, or the budget is spent:
    /// the feed is read to its end even after fn-up.
    func waitForAppended(_ count: Int) async {
        var yields = 0
        while appended < count, yields < Self.yieldBudget, !Task.isCancelled {
            await Task.yield()
            yields += 1
        }
    }

    /// The test calls this right before `attempt.finish`: decodes logged after it are fn-up's.
    func markFnUp() {
        state.withLock { $0.fnUp = true }
    }

    /// Yields until a decode for each of `starts` has been logged, or the budget is spent.
    func waitForDecodes(of starts: [Int]) async {
        var yields = 0
        while !Set(decodes.map(\.start)).isSuperset(of: starts), yields < Self.yieldBudget, !Task.isCancelled {
            await Task.yield()
            yields += 1
        }
    }

    private func record(samples: [Int16], start: Int) throws {
        let fails = state.withLock { state in
            state.decodes.append(Decode(start: start, count: samples.count, first: samples.first, afterFnUp: state.fnUp))
            defer { state.failNext = false }
            return state.failNext
        }
        if fails { throw ModelHiccup() }
    }
}

private struct ModelHiccup: Error {}

/// Sample i of a clip is Int16(i % 30_000): distinct across a clip this long, so a
/// window cut from the wrong place shows up as the wrong first sample.
private func clipSamples(count: Int) -> [Int16] {
    (0..<count).map { Int16($0 % 30_000) }
}

/// The clip cut into chunks whose sizes repeat `sizes`, in capture order.
private func chunks(of samples: [Int16], sizes: [Int]) -> [PCMChunk] {
    var chunks: [PCMChunk] = []
    var start = 0
    while start < samples.count {
        let end = min(start + sizes[chunks.count % sizes.count], samples.count)
        chunks.append(PCMChunk(index: chunks.count, samples: Array(samples[start..<end])))
        start = end
    }
    return chunks
}

/// The clip's sample at `index`, or nil past its end: a wrong start must fail a check, not trap.
private func sample(_ samples: [Int16], at index: Int) -> Int16? {
    samples.indices.contains(index) ? samples[index] : nil
}

private func spokenText(_ outcome: SpeechOutcome) -> String? {
    guard case .text(let spoken) = outcome else { return nil }
    return spoken.text
}

/// A cloud link whose network never changes: the process-wide NWPathMonitor
/// would re-arm the idle unload whenever the Mac's network moved mid-test.
private func noNetworkChanges(_ clock: TestClock) -> CloudLink {
    ScriptedCloud(clock: clock, script: []).link
}
