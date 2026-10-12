import Foundation
import Synchronization
import Testing
@testable import LexiconCore
import LexiconDomain
@testable import Transcription

// #201 item 4: an idle unload that has started can swallow a fn-down. A Dictation
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
    // Nothing signals "finish is waiting on the model", so this polls until finish
    // either has its fn-up load limit pending (it waits on a load that has not
    // finished) or has already returned.
    await until { clock.sleepers > 0 || returned.isSet }
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

// MARK: Helpers

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
