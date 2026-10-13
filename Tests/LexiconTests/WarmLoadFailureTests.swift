import Foundation
import Testing
@testable import LexiconCore
import LexiconDomain
@testable import Transcription

// When the fn-down load of the local model throws, fn-up
// answers at once with that failure and never runs the session's finish. Headless:
// a fake model whose load throws and whose session would hang, a TestClock that
// no step advances (so an answer that waited on the load limit would hang and fail
// at the time limit), no mic, keys or network.
//
// At head the session's finish is called and hangs. The test races the outcome
// against that call: the call is recorded as an Issue and released, so a red run
// ends instead of hanging the suite.

@Test(.timeLimit(.minutes(1))) func aFailedWarmLoadAnswersAtOnceWithTheLoadFailure() async throws {
    let run = await finishAfterFailedLoad(WarmLoadBroke())

    // The fn-down load was tried, so the failure below is the model's, not a missing model.
    #expect(run.loadAttempts >= 1)
    #expect(run.sessionFinishes == 0)
    guard let outcome = run.outcome, case .unavailable(.localModelFailed(_)) = outcome else {
        Issue.record("expected localModelFailed at once, got \(String(describing: run.outcome))")
        return
    }
}

@Test(.timeLimit(.minutes(1))) func aWarmLoadWithNoInstalledModelAnswersAtOnceWithNoModel() async throws {
    let run = await finishAfterFailedLoad(LocalModelNotInstalled(.parakeetUnified))

    // Without this, a plan with no local model would also answer noModel, and pass.
    #expect(run.loadAttempts >= 1)
    #expect(run.sessionFinishes == 0)
    guard let outcome = run.outcome, case .unavailable(.noModel) = outcome else {
        Issue.record("expected noModel at once, got \(String(describing: run.outcome))")
        return
    }
}

// MARK: Helpers

private struct WarmLoadBroke: Error {}

/// What one Dictation's `finish` answered after its fn-down load failed.
private struct FailedLoadRun {
    /// nil when `finish` never returned.
    let outcome: SpeechOutcome?
    let loadAttempts: Int
    let sessionFinishes: Int
}

/// What the race between `finish` and the session's finish can report first.
private enum WarmRace: Sendable {
    case outcome(SpeechOutcome)
    case sessionFinishCalled
}

/// Runs one Dictation whose fn-down load throws `failure`, and reports the outcome
/// of `finish` (if it returns) and how often the session's finish was called. If the
/// session's finish is called, that is recorded as an Issue and released, so the
/// run ends. Nothing advances the clock.
private func finishAfterFailedLoad(_ failure: any Error) async -> FailedLoadRun {
    let (races, post) = AsyncStream<WarmRace>.makeStream()
    let clock = TestClock()
    let model = HangingWarmModel(failure: failure, announce: post)
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: .defaults, access: nil, terms: [])
    let finishing = Task {
        let outcome = await engine.begin(feed: finishedFeed(), plan: plan).finish(AudioClip(samples: [1, 2, 3]))
        post.yield(.outcome(outcome))
        post.finish()
    }

    var outcome: SpeechOutcome?
    for await race in races {
        switch race {
        case .outcome(let answer):
            outcome = answer
        case .sessionFinishCalled:
            Issue.record("the session's finish ran after the fn-down load failed, so finish waited on the session")
            await model.releaseSessions()
        }
    }
    await finishing.value
    return FailedLoadRun(outcome: outcome, loadAttempts: await model.loadAttempts,
                         sessionFinishes: await model.sessionFinishes)
}

/// A local model whose fn-down load throws, and whose session's finish records the
/// call and then waits until the test releases it.
private actor HangingWarmModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private let failure: any Error
    private let announce: AsyncStream<WarmRace>.Continuation
    private(set) var isResident = false
    private(set) var loadAttempts = 0
    private(set) var sessionFinishes = 0
    private var hung: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(failure: any Error, announce: AsyncStream<WarmRace>.Continuation) {
        self.failure = failure
        self.announce = announce
    }

    func load() throws {
        loadAttempts += 1
        throw failure
    }

    func unload() {}

    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { _ in await self.hangUntilReleased() }
    }

    private func hangUntilReleased() async -> String {
        sessionFinishes += 1
        announce.yield(.sessionFinishCalled)
        if !released { await withCheckedContinuation { hung.append($0) } }
        return "Hello."
    }

    func releaseSessions() {
        released = true
        for waiter in hung { waiter.resume() }
        hung = []
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
