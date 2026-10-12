import Foundation
import Synchronization
import Testing
import LexiconDomain
@testable import Transcription

// #201, item 1: the local side of `SpeechEngine.finish` has its own limit, 30 s plus a
// quarter of the clip's length, counted from when the load check passes. A local model
// whose session never answers must get an answer at that limit, with or without a cloud
// model in the plan. Headless: a fake clock, a fake model, a scripted cloud. Each wait is
// an explicit signal; a missing signal fails at the time limit.

@Test(.timeLimit(.minutes(1))) func aHungLocalModelIsAnsweredAtThirtyAndAQuarterSecondsForAHalfSecondClip() async throws {
    let clock = TestClock()
    let model = HangingLocalModel()
    let engine = SpeechEngine(local: model, cloud: noNetworkChanges(clock), clock: clock)
    let plan = SpeechPlan.make(preferences: .defaults, access: nil, terms: [])
    defer { model.hung.release() }

    let outcome = await answerAtTheLimit(engine: engine, plan: plan, clock: clock, hung: model.hung)

    guard case .unavailable(let reason) = outcome, case .localModelFailed = reason else {
        Issue.record("expected localModelFailed at the limit, got \(outcome)")
        return
    }
    #expect(reason.waits)
    #expect(reason.waitsForNetwork == false)
}

@Test(.timeLimit(.minutes(1))) func aHungLocalModelIsAnsweredAtTheSameLimitWhenTheCloudFailedAtOnce() async throws {
    let clock = TestClock()
    let model = HangingLocalModel()
    // The socket never opens: the cloud session fails before the limit, and local is the only engine left.
    let cloud = ScriptedCloud(clock: clock, script: [], connectError: URLError(.cannotConnectToHost))
    let engine = SpeechEngine(local: model, cloud: cloud.link, clock: clock)
    guard let access = CloudAccess.granted(by: cloudPreferences, for: .app(.unknown), keys: fakeKeys) else {
        Issue.record("the cloud access was denied for a standard-privacy Dictation")
        return
    }
    let plan = SpeechPlan.make(preferences: cloudPreferences, access: access, terms: [])
    defer { model.hung.release() }

    let outcome = await answerAtTheLimit(engine: engine, plan: plan, clock: clock, hung: model.hung)

    guard case .unavailable(let reason) = outcome, case .localModelFailed = reason else {
        Issue.record("expected localModelFailed at the limit, got \(outcome)")
        return
    }
    #expect(reason.waits)
    #expect(reason.waitsForNetwork == false)
}

// MARK: Helpers

private let fakeKeys: @Sendable (CredentialID) -> String? = { _ in "fake-key" }

/// Starts one Dictation's `finish` on a half-second clip and runs the clock to the limit.
/// Checks the answer is still pending one millisecond before it, then returns the outcome.
private func answerAtTheLimit(engine: SpeechEngine, plan: SpeechPlan, clock: TestClock,
                              hung: HangingSession) async -> SpeechOutcome {
    let returned = Flag()
    let finishing = Task {
        let outcome = await engine.begin(feed: finishedFeed(), plan: plan)
            .finish(AudioClip(samples: syntheticSamples(count: 8_000)))
        returned.set()
        return outcome
    }
    // The limit is 30 s plus a quarter of the clip's 0.5 s, counted from the load check, which
    // passes at once here: the clock is still at zero, so the limit's sleep ends at 30.125 s.
    await clock.waitForSleep(endingAt: .milliseconds(30_125))
    await clock.advance(by: .milliseconds(30_124))
    #expect(returned.isSet == false)  // still pending 1 ms before the limit
    await clock.advance(by: .milliseconds(1))
    return await outcome(of: finishing, releasing: hung)
}

/// The attempt's outcome. A cancelled test (its time limit) releases the parked session
/// first, so no task stays parked behind a missing answer.
private func outcome(of finishing: Task<SpeechOutcome, Never>, releasing hung: HangingSession) async -> SpeechOutcome {
    await withTaskCancellationHandler {
        await finishing.value
    } onCancel: {
        hung.release()
    }
}

private let cloudPreferences: Preferences = {
    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    return preferences
}()

private final class Flag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

/// A local session whose `finish` never answers until `release` is called.
private final class HangingSession: LocalSession, Sendable {
    private struct State {
        var waiting: CheckedContinuation<String, any Error>?
        var released = false
    }
    private let state = Mutex(State())

    func append(_ samples: [Int16]) {}

    func finish(_ clip: AudioClip) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let answerNow = state.withLock { state -> Bool in
                if state.released { return true }
                state.waiting = continuation
                return false
            }
            if answerNow { continuation.resume(returning: "Hello.") }
        }
    }

    func cancel() {}

    /// Lets a parked `finish` answer, so nothing is left waiting when a test ends.
    func release() {
        let waiting = state.withLock { state -> CheckedContinuation<String, any Error>? in
            state.released = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(returning: "Hello.")
    }
}

/// A resident local model: loads at once, and its one session hangs.
private actor HangingLocalModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    nonisolated let hung = HangingSession()

    var isResident: Bool { true }
    func load() {}
    func unload() {}
    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession { hung }
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
