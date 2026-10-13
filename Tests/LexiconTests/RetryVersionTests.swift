import Foundation
import Testing
@testable import LexiconCore
import History
import LexiconDomain
import Transcription

// A Retry keeps the text it replaces as an earlier version (#213), headless: the
// real Conductor on a synthetic WAV, a local engine that hears a different text
// each time, and History read back through HistoryReader.detail. Retried text is
// never typed, so no destination is involved.

/// Hears `texts` in order, then the last one again. `nil`: no model installed yet.
private actor ChangingTranscriber: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private var texts: [String?]

    init(_ texts: [String?]) { self.texts = texts }

    var isResident: Bool { true }
    func load() {}
    func unload() {}
    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { clip in try await self.transcribe(clip, terms: terms, priority: priority) }
    }

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) throws -> String {
        let text = texts.count > 1 ? texts.removeFirst() : texts[0]
        guard let text else { throw LocalModelNotInstalled(model) }
        return text
    }
}

private let parakeet = SpeechModel.local(.parakeetUnified)
private let museVoice = SpeechModel.cloud(.museVoice)

/// History stores replace times in whole milliseconds, so a bound taken from `Date()`
/// can sit half a millisecond off the stored value.
private let slack: TimeInterval = 0.001

private let withCloud: Preferences = {
    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    return preferences
}()

/// HeadlessSystem's Secrets read the cloud key from the environment, as lexicon-eval does.
/// A fake key, set once; no socket leaves the process (the scripted cloud answers).
private let fakeKeyIsSet: Bool = {
    setenv(Secrets.environmentName(for: .speech(.museVoice)), "fake-speech-key", 1)
    return true
}()

private func system(_ paths: AppPaths, hearing texts: String?...) throws -> HeadlessSystem {
    try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                            local: ChangingTranscriber(texts), clock: TestClock())
}

private func wav() throws -> URL {
    try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: try scratchDirectory())
}

/// The row as the History window reads it, versions and earlier versions included.
@MainActor
private func detail(_ paths: AppPaths, _ id: DictationID) throws -> HistoryDetail {
    try #require(HistoryReader(paths: paths).detail(id))
}

@MainActor @Test func aRetryKeepsTheTextItReplacesAsTheEarlierVersion() async throws {
    let paths = AppPaths.temporary()
    let system = try system(paths, hearing: "first try", "second try")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    await system.history.flush()
    let old = try detail(paths, first.id)
    let oldCleaned = try #require(old.versions?.cleaned)
    let oldFinal = try #require(old.row.finalText)

    let before = Date()
    let retried = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()
    let after = Date()

    let now = try detail(paths, first.id)
    #expect(now.versions?.model == "second try")
    #expect(now.row.finalText == retried.versions?.cleaned)
    #expect(now.row.finalText != oldFinal)
    #expect(now.earlier.count == 1)
    let kept = try #require(now.earlier.first)
    #expect(kept.cleaned == oldCleaned)
    #expect(kept.final == oldFinal)
    #expect(kept.model == parakeet)
    #expect(kept.replacedAt >= before.addingTimeInterval(-slack))
    #expect(kept.replacedAt <= after.addingTimeInterval(slack))
}

// The cloud answers the first Dictation on the fake clock, so the Retry is the only
// engine that can be the one that heard the new text.
@MainActor @Test(.timeLimit(.minutes(1))) func anEarlierVersionKeepsTheEngineThatHeardItNotTheOneThatHearsTheRetry() async throws {
    _ = fakeKeyIsSet
    let paths = AppPaths.temporary()
    let clock = TestClock()
    let cloud = ScriptedCloud(clock: clock, script: Reply.finalText("cloud heard this", after: .milliseconds(100)))
    let system = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: withCloud,
                                         local: ChangingTranscriber(["local heard this", "local heard that"]),
                                         cloud: cloud.link, clock: clock)
    let clip = try wav()
    let running = Task { await system.conductor.dictate(file: clip, pace: .asFastAsPossible) }
    await clock.waitForSleep(endingAt: .milliseconds(100))  // the provider's answer
    await clock.advance(by: .milliseconds(100))
    let first = await running.value
    await system.history.flush()
    #expect(first.model == museVoice)
    let old = try detail(paths, first.id)

    _ = await system.conductor.retry(first.id, with: .local(.parakeetUnified))
    await system.history.flush()

    let now = try detail(paths, first.id)
    #expect(now.row.model == parakeet)
    #expect(now.earlier.map(\.model) == [museVoice])
    #expect(now.earlier.first?.final == old.row.finalText)
}

@MainActor @Test func twoRetriesLeaveTwoEarlierVersionsNewestFirst() async throws {
    let paths = AppPaths.temporary()
    let system = try system(paths, hearing: "first try", "second try", "third try")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    await system.history.flush()
    let one = try detail(paths, first.id)

    _ = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()
    let two = try detail(paths, first.id)

    _ = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()
    let three = try detail(paths, first.id)

    let finals = [try #require(one.row.finalText), try #require(two.row.finalText), try #require(three.row.finalText)]
    let oneCleaned = try #require(one.versions?.cleaned)
    let twoCleaned = try #require(two.versions?.cleaned)
    #expect(Set(finals).count == 3)  // three different texts, so the order is visible
    #expect(three.earlier.map(\.final) == [finals[1], finals[0]])
    #expect(three.earlier.map(\.cleaned) == [twoCleaned, oneCleaned])
}

@MainActor @Test func aRetryThatHearsTheSameWordsAgainStillKeepsTheOldVersion() async throws {
    let paths = AppPaths.temporary()
    let system = try system(paths, hearing: "same words", "same words")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    await system.history.flush()
    let before = try detail(paths, first.id)

    let retried = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()

    let now = try detail(paths, first.id)
    #expect(retried.versions != nil)
    #expect(now.earlier.count == 1)
    #expect(now.earlier.first?.final == before.row.finalText)
    #expect(now.earlier.first?.cleaned == before.versions?.cleaned)
}

/// " " is silence to the engine; "Um." is text that Cleanup empties.
@MainActor @Test(arguments: [" ", "Um."]) func aRetryThatHearsNothingSavesNoVersion(_ heard: String) async throws {
    let paths = AppPaths.temporary()
    let system = try system(paths, hearing: "kept text", heard)
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    await system.history.flush()
    let before = try #require(await system.history.dictation(first.id))

    _ = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()

    let now = try detail(paths, first.id)
    #expect(now.earlier.isEmpty)
    #expect(await system.history.dictation(first.id) == before)
}

@MainActor @Test func aRetryThatNeedsTheAudioSavesNoVersion() async throws {
    let paths = AppPaths.temporary()
    let system = try system(paths, hearing: "kept text", "new text")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    // Aged out: 15 days on, retention removes the audio and keeps the text.
    await system.history.sweepAudio(now: Date().addingTimeInterval(15 * 86_400))
    let before = try #require(await system.history.dictation(first.id))
    #expect(before.audio == .expired)

    _ = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()

    let now = try detail(paths, first.id)
    #expect(now.earlier.isEmpty)
    #expect(await system.history.dictation(first.id) == before)
}

@MainActor @Test func aRetryOfAWaitingDictationSavesNoVersion() async throws {
    // No model yet: the Dictation waits and keeps its own tries. The clock never
    // moves, so its next own try never comes during the test.
    let paths = AppPaths.temporary()
    let clock = TestClock()
    let system = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                                         local: ChangingTranscriber([nil, "found it"]), clock: clock)
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    #expect(first.status == .waiting)
    await system.history.flush()
    let before = try #require(await system.history.dictation(first.id))

    _ = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()

    let now = try detail(paths, first.id)
    #expect(now.earlier.isEmpty)
    #expect(await system.history.dictation(first.id) == before)
}

@MainActor @Test func aFailedDictationThatGetsTextFromRetryHasNoEarlierVersion() async throws {
    let paths = AppPaths.temporary()
    let system = try system(paths, hearing: "", "found it")  // silence first: the Dictation fails
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    #expect(first.status == .failed)

    let retried = await system.conductor.retry(first.id, with: .local(.parakeetUnified))
    await system.history.flush()

    let now = try detail(paths, first.id)
    #expect(now.row.finalText != nil)
    #expect(now.row.finalText == retried.versions?.cleaned)
    #expect(now.earlier.isEmpty)
}

// The row as it was includes the engines Show Versions lists: a Retry that cleans to
// blank adds none. The cloud is on with the network down, so its try is a losing "failed".
@MainActor @Test(.timeLimit(.minutes(1))) func aRetryThatCleansToBlankAddsNoEngineAttemptToTheRow() async throws {
    let paths = AppPaths.temporary()
    let clip = try wav()
    let first: DictationResult
    do {
        // Released before the next system opens: one store per data folder.
        let dictating = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                                                local: ScriptedTranscriber(text: "kept text"), clock: TestClock())
        first = await dictating.conductor.dictate(file: clip, pace: .asFastAsPossible)
        await dictating.history.flush()
    }
    let before = try detail(paths, first.id)

    let retrying = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: withCloud,
                                           local: ScriptedTranscriber(text: "Um."),
                                           cloud: ScriptedCloud(clock: TestClock(), script: [], networkUp: false).link,
                                           clock: TestClock())
    let retried = await retrying.conductor.retry(first.id, with: nil)
    await retrying.history.flush()

    #expect(retried.versions == nil)
    let now = try detail(paths, first.id)
    #expect(now.earlier.isEmpty)
    #expect(now.attempts == before.attempts)
}
