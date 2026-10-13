import Foundation
import Synchronization
import Testing
@testable import LexiconCore
import LexiconDomain
@testable import Transcription

// An idle unload that has started can swallow a fn-down. A Dictation
// that begins while the unload is held must wait for the unload to end, then load
// the model, before its text is decoded. Through SpeechEngine, with a fake local
// model whose unload the test holds and a fake clock: no Neural Engine, no
// wall-clock wait. Every step waits on a signal, and the time limit is the hang guard.

@Test(.timeLimit(.minutes(1))) func aDictationThatBeginsDuringAnIdleUnloadWaitsForTheUnloadThenLoadsTheModel() async throws {
    let (unloadStarts, unloadStarted) = AsyncStream<Void>.makeStream()
    let (releases, release) = AsyncStream<Void>.makeStream()
    let model = HeldUnloadModel(unloadStarted: unloadStarted, releases: releases)
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: tenMinuteLinger, access: nil, terms: [])

    // The first Dictation loads the model, and its idle timer arms at the linger.
    let first = await engine.begin(feed: finishedFeed(), plan: plan).finish(AudioClip(samples: [1, 2, 3]))
    guard case .text(let firstHeard) = first else {
        Issue.record("expected text, got \(first)")
        return
    }
    #expect(firstHeard.text == "Hello.")
    #expect(await model.loads == 1)
    await clock.waitForSleep(endingAt: .seconds(600))

    // The idle timer fires, and the unload starts and is held by the test.
    await clock.advance(by: .seconds(600))
    for await _ in unloadStarts { break }

    // A new Dictation begins while the unload is held. Its finish runs in a task
    // that records when it returns, so the test can tell whether it has.
    let returned = ReturnFlag()
    let second = Task {
        let outcome = await engine.begin(feed: finishedFeed(), plan: plan).finish(AudioClip(samples: [1, 2, 3]))
        returned.set()
        return outcome
    }
    // finish waits on a load that has not finished, so its 2 s fn-up load limit is pending.
    await clock.waitForSleep(endingAt: .seconds(602))
    #expect(!returned.isSet, "finish answered while the idle unload was still held")

    // Only now does the unload end. The model loads again and the text comes back.
    release.yield()
    let outcome = await second.value
    guard case .text(let heard) = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(heard.text == "Hello.")
    #expect(await model.loads == 2, "the model was not loaded again after the unload")
    let decodes = await model.decodes
    #expect(decodes.count == 2)
    #expect(decodes.last?.resident == true, "the session decoded while the model was not resident")
    #expect(decodes.last?.loads == 2, "the session decoded before the model was loaded again")
}

@Test(.timeLimit(.minutes(1))) func privateModeTurnedOnDuringAHeldUnloadReturnsAndLoadsTheModelAfterIt() async throws {
    // A settings change never waits on an unload: one stuck behind a hung model call
    // would stop every later settings and network change from reaching the model.
    let (unloadStarts, unloadStarted) = AsyncStream<Void>.makeStream()
    let (releases, release) = AsyncStream<Void>.makeStream()
    let model = HeldUnloadModel(unloadStarted: unloadStarted, releases: releases)
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    await engine.warmUp(tenMinuteLinger)
    await clock.waitForSleep(endingAt: .seconds(600))
    await clock.advance(by: .seconds(600))
    for await _ in unloadStarts { break }

    var privateMode = tenMinuteLinger
    privateMode.privacy = .private
    let changed = ReturnFlag()
    let changing = Task {
        await engine.preferencesChanged(privateMode)
        changed.set()
    }
    // Returns at the time limit if the change is parked, so that fails here, not hangs.
    await until { changed.isSet }
    #expect(changed.isSet, "the settings change waited on the held unload")
    #expect(await model.loads == 1)

    // Private mode keeps the model loaded: once the unload ends, it loads again.
    release.yield()
    await changing.value
    await until { await model.loads == 2 }
    #expect(await model.isResident)
}

@Test(.timeLimit(.minutes(1))) func aDictationCancelledBehindAStuckUnloadStillEndsItsHold() async throws {
    // An unload can sit behind a hung model call for good. A Dictation begun meanwhile
    // waits on it to load, but its hold on the model still ends when it is cancelled.
    let (unloadStarts, unloadStarted) = AsyncStream<Void>.makeStream()
    let (releases, release) = AsyncStream<Void>.makeStream()
    let model = HeldUnloadModel(unloadStarted: unloadStarted, releases: releases)
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: tenMinuteLinger, access: nil, terms: [])
    await engine.warmUp(tenMinuteLinger)
    await clock.waitForSleep(endingAt: .seconds(600))
    await clock.advance(by: .seconds(600))
    for await _ in unloadStarts { break }

    await engine.begin(feed: finishedFeed(), plan: plan).cancel()
    // The hold ended, so the idle unload arms again: its linger ends 600 s from now.
    await clock.waitForSleep(endingAt: .seconds(1_200))
    #expect(await engine.residency?.unloadScheduled == true, "the cancelled Dictation still holds the model")
    release.yield()
}

@Test(.timeLimit(.minutes(1))) func aFnDownWaitsForASecondIdleUnloadStillRunningWhenTheFirstEnds() async throws {
    // A Dictation that ends while an idle unload sits behind a hung call re-arms the
    // linger, so a second unload can start before the first ends. When the first ends,
    // the second still runs: a fn-down must wait for it too, or the model goes away
    // under the Dictation.
    let model = GatedUnloadModel()
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: tenMinuteLinger, access: nil, terms: [])
    await engine.warmUp(tenMinuteLinger)
    await clock.waitForSleep(endingAt: .seconds(600))
    await clock.advance(by: .seconds(600))
    await model.untilUnloadsStarted(1)

    await engine.begin(feed: finishedFeed(), plan: plan).cancel()
    await clock.waitForSleep(endingAt: .seconds(1_200))
    await clock.advance(by: .seconds(600))
    await model.untilUnloadsStarted(2)

    await model.endOldestUnload()  // the hung call returns; the second unload still runs
    let finishing = Task {
        await engine.begin(feed: finishedFeed(), plan: plan).finish(AudioClip(samples: [1, 2, 3]))
    }
    // fn-up waits on a load that waits on the second unload: its 2 s load limit is pending.
    // Returns at the time limit if fn-down loaded at once instead.
    await clock.waitForSleep(endingAt: .seconds(1_202))
    await model.endOldestUnload()
    let outcome = await finishing.value
    guard case .text = outcome else {
        Issue.record("expected text, got \(outcome)")
        return
    }
    #expect(await model.decodes == [true], "the Dictation decoded with the model unloaded under it")
    #expect(await model.loadsDuringAnUnload == 0, "fn-down loaded the model while the second unload still ran")
}

@Test(.timeLimit(.minutes(1))) func aLoadForADictationAlreadyEndedStillUnloadsAfterTheLinger() async throws {
    // A cancelled Dictation's fn-down load waits through two stuck unloads, then loads
    // with no Dictation left to hold the model: the idle unload must start again.
    let model = GatedUnloadModel()
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: tenMinuteLinger, access: nil, terms: [])
    await engine.warmUp(tenMinuteLinger)
    await clock.waitForSleep(endingAt: .seconds(600))
    await clock.advance(by: .seconds(600))
    await model.untilUnloadsStarted(1)

    await engine.begin(feed: finishedFeed(), plan: plan).cancel()
    await clock.waitForSleep(endingAt: .seconds(1_200))
    await clock.advance(by: .seconds(600))
    await model.untilUnloadsStarted(2)

    await model.endOldestUnload()
    await model.endOldestUnload()  // the cancelled Dictation's load now runs, for nobody
    // Its linger, 600 s from now. Returns at the time limit if nothing arms it.
    await clock.waitForSleep(endingAt: .seconds(1_800))
    guard !Task.isCancelled else {
        Issue.record("the model stayed loaded with no Dictation and no idle unload armed")
        return
    }
    await clock.advance(by: .seconds(600))
    await model.untilUnloadsStarted(3)
    await model.endOldestUnload()
}

// MARK: Helpers

/// Holds each unload until the test ends it, oldest first; `isResident` clears when
/// an unload ends, as a real one would. Records whether the model was resident at each decode.
private actor GatedUnloadModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private(set) var isResident = false
    private(set) var decodes: [Bool] = []
    /// Loads made while an unload was still held: each one is dropped when that unload ends.
    private(set) var loadsDuringAnUnload = 0
    private var unloadsStarted = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(count: Int, wake: CheckedContinuation<Void, Never>)] = []

    func load() {
        if !held.isEmpty { loadsDuringAnUnload += 1 }
        isResident = true
    }

    func unload() async {
        unloadsStarted += 1
        let ready = watchers.filter { $0.count <= unloadsStarted }
        watchers.removeAll { $0.count <= unloadsStarted }
        for watcher in ready { watcher.wake.resume() }
        await withCheckedContinuation { held.append($0) }
        isResident = false
    }

    func untilUnloadsStarted(_ count: Int) async {
        guard unloadsStarted < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    func endOldestUnload() { held.removeFirst().resume() }

    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { _ in await self.decode() }
    }

    private func decode() -> String {
        decodes.append(isResident)
        return "Hello."
    }
}

private let tenMinuteLinger: Preferences = {
    var preferences = Preferences.defaults
    preferences.localModelLinger = .seconds(600)
    return preferences
}()

/// Set once, when an attempt's finish returns.
private final class ReturnFlag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

/// A local model whose unload takes time: it runs until the test releases it, and
/// `isResident` clears only when the unload ends, as a real unload would.
private actor HeldUnloadModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private(set) var isResident = false
    private(set) var loads = 0
    /// What the session saw at each decode: whether the model was resident, and how many loads it had had.
    private(set) var decodes: [Decode] = []
    private let unloadStarted: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>

    struct Decode: Sendable {
        let resident: Bool
        let loads: Int
    }

    init(unloadStarted: AsyncStream<Void>.Continuation, releases: AsyncStream<Void>) {
        self.unloadStarted = unloadStarted
        self.releases = releases
    }

    func load() {
        loads += 1
        isResident = true
    }

    func unload() async {
        unloadStarted.yield()
        for await _ in releases { break }
        isResident = false
    }

    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { clip in await self.transcribe(clip) }
    }

    func transcribe(_ clip: AudioClip) -> String {
        decodes.append(Decode(resident: isResident, loads: loads))
        return "Hello."
    }
}

private func finishedFeed() -> AudioFeed {
    let (feed, input) = AudioFeed.makeStream()
    input.finish()
    return feed
}

/// A cloud link whose network never changes: the process-wide NWPathMonitor
/// would re-arm the idle unload whenever the Mac's network moved mid-test.
private func noNetworkChanges(_ clock: TestClock) -> CloudLink {
    ScriptedCloud(clock: clock, script: []).link
}
