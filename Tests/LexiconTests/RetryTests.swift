import Foundation
import Testing
@testable import LexiconCore
import AudioCapture
import History
import LexiconDomain
import Transcription

// History's ⋯ > Retry (#64), headless: the real Conductor on a synthetic WAV,
// a local engine that hears something different each time, a destination that
// records what would have been typed. Retried text is never typed.

/// Hears `texts` in order, then the last one again.
private actor ChangingTranscriber: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private var texts: [String]

    init(_ texts: [String]) { self.texts = texts }

    var isResident: Bool { true }
    func load() {}
    func unload() {}
    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) -> String {
        texts.count > 1 ? texts.removeFirst() : texts[0]
    }
}

private func system(hearing texts: String...) throws -> HeadlessSystem {
    try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                            local: ChangingTranscriber(texts))
}

private func wav() throws -> URL {
    try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: try scratchDirectory())
}

@Test func retryReplacesTheTextInHistoryAndTypesNothing() async throws {
    let system = try system(hearing: "first try", "second try")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    #expect(first.status == .inserted)
    let typed = await system.conductor.destination.delivered

    let retried = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()

    #expect(retried.versions?.model == "second try")
    let row = try #require(await system.history.dictation(first.id))
    #expect(row.status == .inserted)  // it was typed once; the retry does not change that
    #expect(row.versions?.model == "second try")
    #expect(row.finalText == retried.versions?.cleaned)
    #expect(await system.conductor.destination.delivered == typed)  // nothing typed again
}

@Test func aFailedDictationThatGetsTextFromRetryBecomesNotInserted() async throws {
    let system = try system(hearing: "", "found it")  // silence first: no text, so it fails
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    #expect(first.status == .failed)

    let retried = await system.conductor.retry(first.id, with: .local(.parakeetUnified))
    await system.history.flush()

    #expect(retried.status == .notInserted)
    let row = try #require(await system.history.dictation(first.id))
    #expect(row.status == .notInserted)
    #expect(row.finalText == retried.versions?.cleaned)
    #expect(row.finalText != nil)
    #expect(await system.conductor.destination.delivered.isEmpty)
}

@Test func aRetryThatHearsNothingLeavesTheRowAsItWas() async throws {
    let system = try system(hearing: "kept text", " ")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    await system.history.flush()
    let before = try #require(await system.history.dictation(first.id))

    let retried = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()

    #expect(retried.versions == nil)
    #expect(await system.history.dictation(first.id) == before)
}

@Test func aCloudModelCannotBePickedBeforeM2() async throws {
    // Local only until the cloud race lands: a forced cloud model has no engine to run.
    let system = try system(hearing: "kept text", "cloud text")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    await system.history.flush()
    let before = try #require(await system.history.dictation(first.id))

    let retried = await system.conductor.retry(first.id, with: .cloud(.museVoice))
    await system.history.flush()

    #expect(retried.versions == nil)
    #expect(await system.history.dictation(first.id) == before)
}

@Test func retryNeedsTheAudio() async throws {
    let system = try system(hearing: "kept text", "new text")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    // Aged out: 15 days on, retention removes the audio and keeps the text.
    await system.history.sweepAudio(now: Date().addingTimeInterval(15 * 86_400))
    let before = try #require(await system.history.dictation(first.id))
    #expect(before.audio == .expired)

    let retried = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()

    #expect(retried.versions == nil)
    #expect(await system.history.dictation(first.id) == before)
}

@Test func retryOfADeletedDictationDoesNothing() async throws {
    let system = try system(hearing: "kept text", "new text")
    let first = await system.conductor.dictate(file: try wav(), pace: .asFastAsPossible)
    system.history.record(.deleted(first.id))

    let retried = await system.conductor.retry(first.id, with: nil)
    await system.history.flush()

    #expect(retried.versions == nil)
    #expect(await system.history.dictation(first.id) == nil)
}

@Test func aRetryInHistoryDoesNotAskForPasteLast() async throws {
    // A live Dictation that failed, then Retry in History: Jake is looking at the
    // row, so the pill must not tell him to paste it.
    let system = try system(hearing: "found it")
    let id = DictationID()
    let recorder = Recorder()
    let capture = try await recorder.start(.file(try wav(), pace: .asFastAsPossible),
                                           writingTo: system.history.audioURL(for: id))
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()
    system.history.record(.began(id, origin: .live, purpose: .type, at: Date(), app: .unknown))
    system.history.record(.audioEnded(id, take.summary))
    system.history.record(.failed(id, reason: "silence"))
    let events = await system.conductor.events()

    let retried = await system.conductor.retry(id, with: nil)

    #expect(retried.status == .notInserted)
    var seen: [ConductorEvent] = []
    for await event in events {
        seen.append(event)
        if case .finished = event { break }
    }
    #expect(!seen.contains { if case .notice(.readyToPaste) = $0 { true } else { false } })
}
