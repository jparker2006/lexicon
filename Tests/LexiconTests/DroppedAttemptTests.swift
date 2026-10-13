import Foundation
import Synchronization
import Testing
@testable import LexiconCore
import LexiconDomain
@testable import Transcription

// An attempt's hold on the local model ends exactly once, however
// the attempt ends. Through SpeechEngine with a fake local model and a fake clock:
// no Neural Engine, no wall-clock wait. Every step waits on a signal (a load, a
// sleep with a given deadline), and the time limit is the hang guard.

/// An attempt begun and dropped with no finish or cancel: its hold must still end,
/// so the linger timer arms once the load is done and the model unloads after it.
@Test(.timeLimit(.minutes(1))) func aDroppedAttemptUnloadsTheModelAfterTheLinger() async throws {
    let model = FakeModel()
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: tenMinuteLinger, access: nil, terms: [])

    _ = await engine.begin(feed: finishedFeed(), plan: plan)  // dropped at once: no finish, no cancel

    for await _ in model.loadSignals { break }  // fn-down's load is done
    // At head nothing ever arms the linger timer, so this wait never returns and the
    // time limit cancels it; the requirement below then records that as the failure.
    await clock.waitForSleep(endingAt: .seconds(600))
    try #require(clock.sleepers == 1, "the dropped attempt never let go of the model: no linger timer")

    await clock.advance(by: .seconds(599))
    #expect(clock.sleepers == 1)
    #expect(await model.isResident)

    await clock.advance(by: .seconds(1))
    await model.waitUntilUnloaded()
    #expect(await model.isResident == false)
    #expect(await model.unloads == 1)
}

/// Dictation 1 is finished and released, so its hold ends once and its linger runs
/// from that end. Dictation 2 begins inside that linger and stays in progress: the
/// model must stay loaded past Dictation 1's linger, and unload only after
/// Dictation 2's own linger, once Dictation 2 has ended its hold.
@Test(.timeLimit(.minutes(1))) func aSecondDictationWithinTheLingerKeepsTheModelUntilItsOwnLingerEnds() async throws {
    let model = FakeModel()
    let clock = TestClock()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: tenMinuteLinger, access: nil, terms: [])

    let first = await engine.begin(feed: finishedFeed(), plan: plan)
    let firstOutcome = await first.finish(AudioClip(samples: [1, 2, 3]))  // finished, then released
    guard case .text(let firstHeard) = firstOutcome else {
        Issue.record("expected text, got \(firstOutcome)")
        return
    }
    #expect(firstHeard.text == "Hello.")
    await clock.waitForSleep(endingAt: .seconds(600))  // Dictation 1's linger, from t = 0
    try #require(clock.sleepers == 1, "Dictation 1's hold did not end once: no linger timer")
    await clock.advance(by: .seconds(300))

    // Dictation 2 begins inside the linger. Its fn-down cancels Dictation 1's timer.
    let second = await engine.begin(feed: finishedFeed(), plan: plan)
    await clock.waitForSleepers(0)

    // t = 600: Dictation 1's linger has passed while Dictation 2 is still in progress.
    await clock.advance(by: .seconds(300))
    #expect(clock.sleepers == 0)
    #expect(await model.isResident)
    #expect(await model.unloads == 0)

    // t = 900: still in progress.
    await clock.advance(by: .seconds(300))
    #expect(await model.isResident)
    #expect(await model.unloads == 0)

    // Dictation 2 ends at t = 900, so its own linger runs to t = 1500.
    let secondOutcome = await second.finish(AudioClip(samples: [1, 2, 3]))
    guard case .text(let secondHeard) = secondOutcome else {
        Issue.record("expected text, got \(secondOutcome)")
        return
    }
    #expect(secondHeard.text == "Hello.")
    await clock.waitForSleep(endingAt: .seconds(1_500))

    await clock.advance(by: .seconds(599))
    #expect(clock.sleepers == 1)
    #expect(await model.isResident)

    await clock.advance(by: .seconds(1))
    await model.waitUntilUnloaded()
    #expect(await model.isResident == false)
    #expect(await model.loads == 1)
    #expect(await model.unloads == 1)
}

// MARK: Helpers

private let tenMinuteLinger: Preferences = {
    var preferences = Preferences.defaults
    preferences.localModelLinger = .seconds(600)
    return preferences
}()

private func finishedFeed() -> AudioFeed {
    let (feed, input) = AudioFeed.makeStream()
    input.finish()
    return feed
}

/// A local model that loads instantly, hears "Hello.", and counts its loads and unloads.
/// `loadSignals` yields once per load, so a test waits for a load instead of polling.
private actor FakeModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    nonisolated let loadSignals: AsyncStream<Void>
    private let loadSignal: AsyncStream<Void>.Continuation
    private(set) var isResident = false
    private(set) var loads = 0
    private(set) var unloads = 0
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let (signals, signal) = AsyncStream<Void>.makeStream()
        loadSignals = signals
        loadSignal = signal
    }

    func load() {
        loads += 1
        isResident = true
        loadSignal.yield(())
    }

    func unload() {
        unloads += 1
        isResident = false
        for waiter in unloadWaiters { waiter.resume() }
        unloadWaiters = []
    }

    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { _ in await self.transcribe() }
    }

    func transcribe() -> String { "Hello." }

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
