import Foundation
import Testing
@testable import History
import AppText
import AudioCapture
import LexiconCore
import LexiconDomain
import Transcription
import WordStore

// Re-speak on the selection path (#83), headless: the real Conductor on a
// synthesized WAV per Dictation, a local engine that hears one queued text per
// clip, and the one simulated field. Jake's selection is set on the destination
// just before the Re-speak, as fn-down would capture it. No mic, keys or network.

/// Hears one text per clip, in the order the clips were dictated, and the last
/// text again after that. Copied in shape from RetryTests' ChangingTranscriber,
/// which is private to that file.
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

/// The span of the first `word` in `text`, in UTF-16 offsets: where a selection of it would sit.
private func span(of word: String, in text: String) throws -> TextSpan {
    let range = try #require(text.range(of: word))
    let location = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
    return TextSpan(location: location, length: word.utf16.count)
}

/// The Fix rows of one Dictation as (kind, before, after). History has no public
/// read of them, so this reads the table the way HistoryStoreTests does.
private func fixes(_ history: HistoryStore, of id: DictationID) async throws -> [[String?]] {
    try await history.read { db in
        try db.query("SELECT kind, text_before, text_after FROM fix WHERE dictation_id = ? ORDER BY at, rowid",
                     [.text(id.description)]).map { [$0.text(0), $0.text(1), $0.text(2)] }
    }
}

/// The events of one Dictation, up to its `finished`. Subscribe before it runs:
/// the stream keeps the newest events, and `finished` is the last one emitted.
private func emitted(_ stream: AsyncStream<ConductorEvent>, until id: DictationID) async -> [ConductorEvent] {
    var seen: [ConductorEvent] = []
    for await event in stream {
        seen.append(event)
        if case .finished(let finished, _) = event, finished == id { break }
    }
    return seen
}

private func isFixNotLanded(_ event: ConductorEvent) -> Bool {
    if case .notice(.fixNotLanded(_)) = event { return true }
    return false
}

@Test(.timeLimit(.minutes(1)))
func aRespeakOfTheSecondOfTwoIdenticalWordsEditsTheSecond() async throws {
    let system = try system(hearing: "the cat saw the cat", "dog")
    let first = try await dictate(system)
    await system.history.flush()
    #expect(first.status == .inserted)
    let typed = await system.destination.fieldText
    #expect(typed == "the cat saw the cat")

    await system.destination.select(TextSpan(location: 16, length: 3))  // the second "cat"
    let events = await system.conductor.events()
    let respeak = try await dictate(system, purpose: .respeak(of: first.id))
    await system.history.flush()

    let field = await system.destination.fieldText
    #expect(field == "the cat saw the dog")
    let finalText = await system.history.dictation(first.id)?.finalText
    #expect(finalText == "the cat saw the dog")
    let rows = try await fixes(system.history, of: first.id)
    #expect(rows == [["respeak", "cat", "dog"]])
    let seen = await emitted(events, until: respeak.id)
    #expect(!seen.contains(where: isFixNotLanded))
}

@Test(.timeLimit(.minutes(1)))
func aRespeakOfTheFirstOfTwoIdenticalWordsEditsTheFirstOnly() async throws {
    let system = try system(hearing: "the cat saw the cat", "dog")
    let first = try await dictate(system)
    await system.history.flush()

    await system.destination.select(TextSpan(location: 4, length: 3))  // the first "cat"
    _ = try await dictate(system, purpose: .respeak(of: first.id))
    await system.history.flush()

    let field = await system.destination.fieldText
    #expect(field == "the dog saw the cat")
    let finalText = await system.history.dictation(first.id)?.finalText
    #expect(finalText == "the dog saw the cat")
    let rows = try await fixes(system.history, of: first.id)
    #expect(rows == [["respeak", "cat", "dog"]])
}

@Test(.timeLimit(.minutes(1)))
func aRespeakWithNoSelectionChangesNothingInTheField() async throws {
    // The no-selection path is the Jev path (#82), not this ticket's: it must stay out of the field.
    let system = try system(hearing: "the cat saw the cat", "dog")
    let first = try await dictate(system)
    _ = try await dictate(system, purpose: .respeak(of: first.id))
    await system.history.flush()

    let field = await system.destination.fieldText
    #expect(field == "the cat saw the cat")
    let finalText = await system.history.dictation(first.id)?.finalText
    #expect(finalText == "the cat saw the cat")
    let rows = try await fixes(system.history, of: first.id)
    #expect(rows.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aSelectionInAnotherDictationEditsTheFieldAndNotTheRespeaksDictation() async throws {
    let system = try system(hearing: "the cat saw the cat", "wire the auth callback", "login")
    let first = try await dictate(system)
    _ = try await dictate(system)  // the second Dictation, typed after the first
    await system.history.flush()

    let before = await system.destination.fieldText
    await system.destination.select(try span(of: "auth", in: before))
    _ = try await dictate(system, purpose: .respeak(of: first.id))
    await system.history.flush()

    let field = await system.destination.fieldText
    #expect(field == before.replacingOccurrences(of: "auth", with: "login"))
    let finalText = await system.history.dictation(first.id)?.finalText
    #expect(finalText == "the cat saw the cat")
    let rows = try await fixes(system.history, of: first.id)
    #expect(rows.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aRespeakKeepsATermsWrittenFormOverALowercaseSelection() async throws {
    let system = try system(hearing: "wire the auth callback into super base now", "Supabase.")
    let first = try await dictate(system)
    await system.history.flush()
    // Added after the first Dictation, so the Term cannot change how it was typed.
    try await system.lexicon.add(Term(text: "Supabase"))

    let before = await system.destination.fieldText
    await system.destination.select(try span(of: "super base", in: before))
    let events = await system.conductor.events()
    let respeak = try await dictate(system, purpose: .respeak(of: first.id))
    await system.history.flush()

    let field = await system.destination.fieldText
    #expect(field == "wire the auth callback into Supabase now")
    let finalText = await system.history.dictation(first.id)?.finalText
    #expect(finalText == "wire the auth callback into Supabase now")
    let seen = await emitted(events, until: respeak.id)
    #expect(!seen.contains(where: isFixNotLanded))
}

@Test(.timeLimit(.minutes(1)))
func aRespeakKeepsTheCapitalOfAWordThatIsNotPlainEnglish() async throws {
    // The same Re-speak with no Term: a name the system word list doesn't hold keeps its capital.
    let system = try system(hearing: "wire the auth callback into super base now", "Supabase.")
    let first = try await dictate(system)
    await system.history.flush()

    let before = await system.destination.fieldText
    await system.destination.select(try span(of: "super base", in: before))
    _ = try await dictate(system, purpose: .respeak(of: first.id))
    await system.history.flush()

    let field = await system.destination.fieldText
    #expect(field == "wire the auth callback into Supabase now")
}

@Test(.timeLimit(.minutes(1)))
func aRespeakLowercasesAPlainEnglishWordToMatchTheSelection() async throws {
    let system = try system(hearing: "the cat saw the cat", "Dog.")
    let first = try await dictate(system)
    await system.history.flush()

    await system.destination.select(TextSpan(location: 16, length: 3))
    _ = try await dictate(system, purpose: .respeak(of: first.id))
    await system.history.flush()

    #expect(await system.destination.fieldText == "the cat saw the dog")
}

@Test(.timeLimit(.minutes(1)))
func aRespeakOfACommonWordDropsItsPeriodAndMatchesTheSelectionsCase() async throws {
    let system = try system(hearing: "the cat saw the cat", "Dog.")
    let first = try await dictate(system)
    await system.history.flush()

    await system.destination.select(TextSpan(location: 16, length: 3))  // the second "cat"
    _ = try await dictate(system, purpose: .respeak(of: first.id))
    await system.history.flush()

    let field = await system.destination.fieldText
    #expect(field == "the cat saw the dog")
    let finalText = await system.history.dictation(first.id)?.finalText
    #expect(finalText == "the cat saw the dog")
}
