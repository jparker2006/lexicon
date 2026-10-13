import Foundation
import Testing
@testable import LexiconCore
import AppText
import AudioCapture
import History
import LexiconDomain
import Transcription

// Re-speak (#83), headless: the real Conductor on synthetic WAVs. A Re-speak may
// change another app's text only through a live target. A Retry or a launch
// recovery of a Re-speak row lands with no target, so the field and History's
// first Dictation stay as they were. No mic, keys or network.

/// Hears `texts` in order, then the last one again: one answer per clip.
private actor QueuedTranscriber: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private var texts: [String]

    init(_ texts: [String]) { self.texts = texts }

    var isResident: Bool { true }
    func load() {}
    func unload() {}
    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { clip in await self.transcribe(clip, terms: terms, priority: priority) }
    }

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) -> String {
        texts.count > 1 ? texts.removeFirst() : texts[0]
    }
}

private func system(hearing texts: String...) throws -> HeadlessSystem {
    try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                            local: QueuedTranscriber(texts), clock: TestClock())
}

private func wav() throws -> URL {
    try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: try scratchDirectory())
}

/// The second "cat" of "the cat saw the cat", in UTF-16 offsets.
private let secondCat = TextSpan(location: 16, length: 3)

@Test(.timeLimit(.minutes(1)))
func aRetriedRespeakWithNoLiveTargetEditsNothing() async throws {
    let system = try system(hearing: "the cat saw the cat", "dog")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    #expect(first.status == .inserted)
    #expect(await system.destination.fieldText == "the cat saw the cat")

    // A Re-speak of the first Dictation, dictated with nothing selected: no replace, History only.
    let respeak = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible,
                                                 purpose: .respeak(of: first.id))
    await system.history.flush()
    #expect(try #require(await system.history.dictation(respeak.id)).purpose == .respeak(of: first.id))

    // Jake selects the second "cat"; the Re-speak then lands by Retry, which captures no target.
    await system.destination.select(secondCat)
    let retried = await system.conductor.retry(respeak.id, with: nil)
    await system.history.flush()

    #expect(retried.versions?.cleaned == "dog")  // its words landed, so the field check below means something
    #expect(await system.destination.fieldText == "the cat saw the cat")
    let row = try #require(await system.history.dictation(first.id))
    #expect(row.finalText == "the cat saw the cat")
}

@Test(.timeLimit(.minutes(1)))
func aLiveRespeakOfASelectedWordReplacesIt() async throws {
    let system = try system(hearing: "the cat saw the cat", "dog")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    #expect(first.status == .inserted)
    #expect(await system.destination.fieldText == "the cat saw the cat")

    // Jake selects the second "cat" and speaks "dog" over it, with the target still live.
    await system.destination.select(secondCat)
    let respeak = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible,
                                                 purpose: .respeak(of: first.id))

    let field = await system.destination.fieldText
    #expect(respeak.versions?.cleaned == "dog")
    #expect(field == "the cat saw the dog")
}

private let app = AppContext(bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: .milliseconds(40), deviceName: "Mic",
                                 storage: .onDisk, gaps: [])

/// When an earlier run began a Dictation: well before any store these tests open.
private func earlier() -> Date { Date().addingTimeInterval(-60) }

/// A closed CAF the way a finished recording leaves it. Copied from HistoryRecoveryTests, where it is private.
private func writeClosedCAF(_ samples: [Int16], at url: URL) async throws {
    let wav = try writeWAV(samples, rate: 16_000, in: try scratchDirectory())
    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: url)
    let ended = try #require(await capture.signals.inputEnded())
    _ = await capture.stop(.released(at: ended))
    await recorder.settle()
    #expect(CAFFile.state(of: url) == .closed)
}

/// Launch recovery takes only what an earlier run wrote, so the next store must open in a later
/// millisecond than the last file. Copied from HistoryRecoveryTests' `relaunch`, where it is private.
private func untilRelaunch() async {
    let written = (Date().timeIntervalSince1970 * 1_000).rounded()
    await until { (Date().timeIntervalSince1970 * 1_000).rounded() > written }
}

@Test(.timeLimit(.minutes(1)))
func aRespeakLeftUnfinishedByACrashEditsNothingWhenRecovered() async throws {
    let paths = AppPaths.temporary()
    // The last run: a Dictation that landed, then a Re-speak of it whose audio ended and whose text never came.
    let lastRun = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                                          local: QueuedTranscriber(["the cat saw the cat"]), clock: TestClock())
    let original = await lastRun.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    #expect(original.status == .inserted)
    let respeak = DictationID()
    lastRun.history.record(.began(respeak, origin: .live, purpose: .respeak(of: original.id), at: earlier(), app: app))
    lastRun.history.record(.audioEnded(respeak, audio))
    try await writeClosedCAF(syntheticSamples(count: 16_000), at: lastRun.history.audioURL(for: respeak))
    await lastRun.history.flush()

    // The relaunch, on the same data folder: a new store, and a new field that starts empty.
    await untilRelaunch()
    let relaunched = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                                             local: QueuedTranscriber(["the cat saw the cat", "dog"]), clock: TestClock())
    // Jake types the same words into the new field, then selects the second "cat" before launch recovery runs.
    let typed = await relaunched.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    #expect(typed.status == .inserted)
    #expect(await relaunched.destination.fieldText == "the cat saw the cat")  // so the field check below means something
    await relaunched.destination.select(secondCat)

    await relaunched.conductor.recover()
    await relaunched.conductor.settle()
    await relaunched.history.flush()

    // Recovery lands the Re-speak with no target: the field does not move, and nothing is typed for it.
    #expect(await relaunched.destination.fieldText == "the cat saw the cat")
    #expect(await relaunched.destination.delivered[respeak] == nil)

    // It reached its recovered landing: its text is in History, and the first Dictation keeps its text.
    let row = try #require(await relaunched.history.dictation(respeak))
    #expect(row.status == .recovered)
    #expect(row.finalText == "dog")
    #expect(row.purpose == .respeak(of: original.id))
    #expect(try #require(await relaunched.history.dictation(original.id)).finalText == "the cat saw the cat")
}
