import Foundation
import Synchronization
import Testing
@testable import LexiconCore
import LexiconDomain
@testable import Transcription

// The local model's residency and failure handling (#47), through the headless
// pipeline with a fake model and a fake clock: no Neural Engine, no waiting on
// the wall clock. Each test waits on a signal, so a time limit turns a missing
// signal into a failure instead of a hang.

@Test(.timeLimit(.minutes(1))) func theModelLoadsOnFnDownAndUnloadsAfterTenIdleMinutes() async throws {
    let model = FakeModel()
    let clock = TestClock()
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: tenMinuteLinger,
                                         local: model, cloud: noNetworkChanges(clock), clock: clock)

    let result = await system.conductor.dictate(file: try shortWAV(), pace: .asFastAsPossible)

    #expect(result.status == .inserted)
    #expect(await model.loads == 1)
    #expect(await model.isResident)

    await clock.waitForSleepers(1)
    await clock.advance(by: .seconds(599))
    #expect(clock.sleepers == 1)
    #expect(await model.isResident)

    await clock.advance(by: .seconds(1))
    await model.waitUntilUnloaded()
    #expect(await model.isResident == false)
}

@Test(.timeLimit(.minutes(1))) func aDictationWithinTheLingerKeepsTheModelLoaded() async throws {
    let model = FakeModel()
    let clock = TestClock()
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: tenMinuteLinger,
                                         local: model, cloud: noNetworkChanges(clock), clock: clock)

    _ = await system.conductor.dictate(file: try shortWAV(), pace: .asFastAsPossible)
    await clock.waitForSleepers(1)
    await clock.advance(by: .seconds(540))
    _ = await system.conductor.dictate(file: try shortWAV(), pace: .asFastAsPossible)
    await clock.waitForSleepers(1)  // the first timer was cancelled at fn-down
    await clock.advance(by: .seconds(540))

    #expect(await model.isResident)
    #expect(await model.loads == 1)
    #expect(clock.sleepers == 1)  // only the second Dictation's timer is left

    await clock.advance(by: .seconds(60))
    await model.waitUntilUnloaded()
    #expect(await model.isResident == false)
}

@Test(.timeLimit(.minutes(1))) func privateModeKeepsTheModelLoaded() async throws {
    let model = FakeModel()
    let clock = TestClock()
    var preferences = tenMinuteLinger
    preferences.privacy = .private
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: preferences,
                                         local: model, cloud: noNetworkChanges(clock), clock: clock)

    let result = await system.conductor.dictate(file: try shortWAV(), pace: .asFastAsPossible)

    #expect(result.status == .inserted)
    #expect(clock.sleepers == 0)  // no unload is ever scheduled
    await clock.advance(by: .seconds(3_600))
    _ = await system.conductor.dictate(file: try shortWAV(), pace: .asFastAsPossible)
    #expect(await model.loads == 1)  // never unloaded, so never loaded again
    #expect(await model.isResident)
}

@Test(.timeLimit(.minutes(1))) func privateModeTurnedOnMidDictationKeepsTheModelLoaded() async throws {
    let model = FakeModel()
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: tenMinuteLinger, access: nil, terms: [])
    var privateMode = tenMinuteLinger
    privateMode.privacy = .private

    let attempt = await engine.begin(feed: finishedFeed(), plan: plan)
    await engine.preferencesChanged(privateMode)
    _ = await attempt.finish(AudioClip(samples: [1, 2, 3]))

    // The fn-down snapshot said standard; Private mode came after it.
    #expect(await engine.residency?.unloadScheduled == false)
    #expect(await model.isResident)
}

@Test(.timeLimit(.minutes(1))) func aBrokenLocalModelIsItsOwnReasonNotTheNetwork() async throws {
    let engine = SpeechEngine(local: FakeModel(failure: ModelBroke()), clock: TestClock())
    let plan = SpeechPlan.make(preferences: .defaults, access: nil, terms: [])

    let outcome = await engine.begin(feed: finishedFeed(), plan: plan).finish(AudioClip(samples: [1, 2, 3]))

    guard case .unavailable(let reason) = outcome, case .localModelFailed = reason else {
        Issue.record("expected localModelFailed, got \(outcome)")
        return
    }
    #expect(reason.waits)
    #expect(reason.waitsForNetwork == false)
}

@Test(.timeLimit(.minutes(1))) func aMissingLocalModelWaitsForAModel() async throws {
    let engine = SpeechEngine(local: FakeModel(failure: LocalModelNotInstalled(.parakeetUnified)), clock: TestClock())
    let plan = SpeechPlan.make(preferences: .defaults, access: nil, terms: [])

    let outcome = await engine.begin(feed: finishedFeed(), plan: plan).finish(AudioClip(samples: [1, 2, 3]))

    guard case .unavailable(.noModel) = outcome else {
        Issue.record("expected noModel, got \(outcome)")
        return
    }
}

@Test(.timeLimit(.minutes(1))) func aBrokenLocalModelKeepsTheAudioWithoutAWaitingForNetworkNotice() async throws {
    let source = syntheticSamples(count: 8_000)
    let wav = try writeWAV(source, rate: 16_000, in: try scratchDirectory())
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                                         local: FakeModel(failure: ModelBroke()), clock: TestClock())
    let events = await system.conductor.events()

    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)
    await system.history.flush()

    #expect(result.status == .waiting)
    var notices: [Notice] = []
    for await event in events {
        if case .notice(let notice) = event { notices.append(notice) }
        if case .finished = event { break }
    }
    #expect(notices.isEmpty)
    let row = try #require(await system.history.dictation(result.id))
    #expect(row.status == .waiting)
    #expect(row.audio == .onDisk)
}

@Test(.timeLimit(.minutes(1))) func withNoLocalModelInThePlanTheEnginesModelIsNotUsed() async throws {
    let model = FakeModel()
    var preferences = Preferences.defaults
    preferences.localModel = nil
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: preferences,
                                         local: model, clock: TestClock())

    let result = await system.conductor.dictate(file: try shortWAV(), pace: .asFastAsPossible)

    #expect(result.status == .waiting)
    #expect(await model.loads == 0)
    #expect(await model.transcribed == 0)
}

@Test(.timeLimit(.minutes(1))) func aWaitForQueuedJobsEndsWhenItsTestIsCancelled() async {
    // A test that waits for a job that never queues must fail at its time limit, which
    // cancels the test's work, not hang the whole run.
    let queue = LocalJobQueue()
    let waiter = Task { await queue.untilWaiting(atLeast: 1) }
    // Parked first, so the cancel has to wake it, not just stop it before it starts.
    // Nothing signals a park, so this polls; it returns on cancel like every wait here.
    await until { await queue.watching > 0 }
    waiter.cancel()
    await waiter.value
}

@Test(.timeLimit(.minutes(1))) func liveWorkGoesAheadOfQueuedBackgroundWork() async throws {
    let queue = LocalJobQueue()
    let order = Order()
    let (release, releasing) = AsyncStream<Void>.makeStream()
    let (started, starting) = AsyncStream<Void>.makeStream()

    let first = Task {
        await queue.run(.background) {
            starting.yield()
            for await _ in release { break }  // holds the Neural Engine until released
            await order.append("first")
        }
    }
    for await _ in started { break }
    let background = Task { await queue.run(.background) { await order.append("background") } }
    await queue.untilWaiting(atLeast: 1)
    let live = Task { await queue.run(.live) { await order.append("live") } }
    await queue.untilWaiting(atLeast: 2)

    releasing.yield()
    await first.value
    await background.value
    await live.value

    #expect(await order.names == ["first", "live", "background"])
}

@Test(.timeLimit(.minutes(1))) func theModelLoadsAtLaunchAndUnloadsAfterTenIdleMinutes() async throws {
    let model = FakeModel()
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)

    await engine.warmUp(tenMinuteLinger)

    #expect(await model.loads == 1)
    #expect(await model.isResident)
    await clock.waitForSleepers(1)
    await clock.advance(by: .seconds(600))
    await model.waitUntilUnloaded()
    #expect(await model.isResident == false)
}

@Test(.timeLimit(.minutes(1))) func aModelStillLoadingTwoSecondsAfterFnUpLeavesTheDictationWaiting() async throws {
    // The first load of a new build compiles for the Neural Engine for about 25 s.
    // Jake never waits that out at the cursor: the Dictation waits instead.
    let model = SlowModel()
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: tenMinuteLinger, access: nil, terms: [])

    let finishing = Task { await engine.begin(feed: finishedFeed(), plan: plan).finish(AudioClip(samples: [1, 2, 3])) }
    await clock.waitForSleepers(1)
    await clock.advance(by: .milliseconds(1_999))
    #expect(clock.sleepers == 1)
    await clock.advance(by: .milliseconds(1))
    let outcome = await finishing.value

    guard case .unavailable(let reason) = outcome, case .localModelLoading = reason else {
        Issue.record("expected localModelLoading, got \(outcome)")
        return
    }
    #expect(reason.waits)
    #expect(reason.waitsForNetwork == false)
    #expect(await model.transcribed == 0)

    // The load finishes in the background and the model then unloads on its idle timer as usual.
    await model.finishLoading()
    await clock.waitForSleepers(1)
    await clock.advance(by: .seconds(600))
    await model.waitUntilUnloaded()
}

@Test(.timeLimit(.minutes(1))) func aModelThatLoadsInTimeTranscribesWithNoWaitingTimerLeft() async throws {
    let model = SlowModel()
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: tenMinuteLinger, access: nil, terms: [])

    let finishing = Task { await engine.begin(feed: finishedFeed(), plan: plan).finish(AudioClip(samples: [1, 2, 3])) }
    await clock.waitForSleepers(1)
    await model.finishLoading()
    let outcome = await finishing.value

    guard case .text(let heard) = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(heard.text == "Hello.")
    await clock.waitForSleepers(1)  // only the idle unload: the load limit was cancelled
}

// MARK: Helpers

private struct ModelBroke: Error {}

private let tenMinuteLinger: Preferences = {
    var preferences = Preferences.defaults
    preferences.localModelLinger = .seconds(600)
    return preferences
}()

private actor Order {
    private(set) var names: [String] = []
    func append(_ name: String) { names.append(name) }
}

private func shortWAV() throws -> URL {
    try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
}

private func finishedFeed() -> AudioFeed {
    let (feed, input) = AudioFeed.makeStream()
    input.finish()
    return feed
}

/// A local model that loads instantly, hears "Hello.", and reports when it unloads.
private actor FakeModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    let failure: (any Error)?
    private(set) var isResident = false
    private(set) var loads = 0
    private(set) var transcribed = 0
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []

    init(failure: (any Error)? = nil) { self.failure = failure }

    func load() throws {
        if let failure { throw failure }
        loads += 1
        isResident = true
    }

    func unload() {
        isResident = false
        for waiter in unloadWaiters { waiter.resume() }
        unloadWaiters = []
    }

    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { clip in try await self.transcribe(clip, terms: terms, priority: priority) }
    }

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) throws -> String {
        if let failure { throw failure }
        transcribed += 1
        return "Hello."
    }

    func waitUntilUnloaded() async {
        guard isResident else { return }
        await withCheckedContinuation { unloadWaiters.append($0) }
    }
}

/// A local model whose load runs until the test calls `finishLoading`.
private actor SlowModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private(set) var isResident = false
    private(set) var transcribed = 0
    private var loading: [CheckedContinuation<Void, Never>] = []
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async {
        guard !isResident else { return }
        await withCheckedContinuation { loading.append($0) }
    }

    func finishLoading() async {
        while loading.isEmpty { await Task.yield() }
        isResident = true
        for waiter in loading { waiter.resume() }
        loading = []
    }

    func unload() {
        isResident = false
        for waiter in unloadWaiters { waiter.resume() }
        unloadWaiters = []
    }

    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { clip in await self.transcribe(clip, terms: terms, priority: priority) }
    }

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) -> String {
        transcribed += 1
        return "Hello."
    }

    func waitUntilUnloaded() async {
        guard isResident else { return }
        await withCheckedContinuation { unloadWaiters.append($0) }
    }
}

/// A cloud link whose network never changes: the process-wide NWPathMonitor
/// would re-arm the idle unload whenever the Mac's network moved mid-test.
private func noNetworkChanges(_ clock: TestClock) -> CloudLink {
    ScriptedCloud(clock: clock, script: []).link
}
