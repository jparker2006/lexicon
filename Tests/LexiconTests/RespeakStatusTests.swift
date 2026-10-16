import Foundation
import Testing
@testable import History
import AppText
import AudioCapture
import LexiconCore
import LexiconDomain
import Transcription
import WordStore

// The status of a Re-speak's own History row (#83), headless: the real Conductor on a
// synthesized WAV per Dictation, a local engine that hears one queued text per clip, and
// the one simulated field, set up as RespeakSelectionTests sets it up. A Re-speak whose
// selection replace lands is `.inserted`; one with nothing selected stays `.notInserted`
// (the no-selection path is Jev's, #82). No mic, keys or network.

/// Hears one text per clip, in the order the clips were dictated, and the last
/// text again after that. Copied from RespeakSelectionTests' HearingInOrder, which is private to that file.
private actor HearingInOrder: LocalTranscriber {
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
                            local: HearingInOrder(texts), clock: TestClock())
}

/// One second of audio, dictated with `purpose`.
private func dictate(_ system: HeadlessSystem, purpose: DictationPurpose = .type) async throws -> DictationResult {
    let wav = try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: try scratchDirectory())
    return await system.conductor.dictate(file: wav, pace: .asFastAsPossible, purpose: purpose)
}

@Test(.timeLimit(.minutes(1)))
func aRespeakThatReplacesTheSelectionLeavesItsOwnRowInserted() async throws {
    let system = try system(hearing: "the cat saw the cat", "dog")
    let first = try await dictate(system)
    await system.history.flush()

    await system.destination.select(TextSpan(location: 16, length: 3))  // the second "cat"
    let respeak = try await dictate(system, purpose: .respeak(of: first.id))
    await system.history.flush()

    // Setup check, not the finding: the replace landed in the field.
    let field = await system.destination.fieldText
    #expect(field == "the cat saw the dog")
    let row = try #require(await system.history.dictation(respeak.id))
    #expect(row.status == .inserted)
}

@Test(.timeLimit(.minutes(1)))
func aRespeakWithNoSelectionLeavesItsOwnRowNotInserted() async throws {
    let system = try system(hearing: "the cat saw the cat", "dog")
    let first = try await dictate(system)
    let respeak = try await dictate(system, purpose: .respeak(of: first.id))
    await system.history.flush()

    // Setup check, not the finding: nothing was selected, so nothing changed in the field.
    let field = await system.destination.fieldText
    #expect(field == "the cat saw the cat")
    let row = try #require(await system.history.dictation(respeak.id))
    #expect(row.status == .notInserted)
}
