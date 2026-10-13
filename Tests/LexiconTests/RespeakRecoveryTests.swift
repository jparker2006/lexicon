import Foundation
import Testing
@testable import LexiconCore
import AppText
import AudioCapture
import History
import LexiconDomain
import Transcription

// Re-speak (#83), headless: the real Conductor on synthetic WAVs. A Re-speak may
// change another app's text only through a live target. A Retry of a Re-speak row
// lands with no target, so the field and History's first Dictation stay as they were.
// No mic, keys or network.

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
