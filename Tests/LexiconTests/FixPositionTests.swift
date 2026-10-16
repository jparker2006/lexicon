import Foundation
import Testing
@testable import History
import AudioCapture
import LexiconDomain

// A Fix says where its `before` sits in the text (#83), so a Re-speak of the
// second of two identical words edits the second. History's write API on a
// throwaway data folder: no mic, no app.

private let app = AppContext(bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: .milliseconds(40), deviceName: "Mic",
                                 storage: .onDisk, gaps: [])
private let parakeet = SpeechModel.local(.parakeetUnified)
private let receipt = InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "f1", caretAfter: 37,
                                       contextBefore: "", contextAfter: "", insertedAt: start.addingTimeInterval(2))

private func makeStore() throws -> (HistoryStore, AppPaths) {
    let paths = AppPaths.temporary()
    return (try HistoryStore(paths: paths), paths)
}

/// A Dictation inserted with `cleaned` as its cleaned text, the way a live dictation leaves it.
private func inserted(_ store: HistoryStore, cleaned: String) async throws -> DictationID {
    let id = DictationID()
    try Data([0, 1]).write(to: store.audioURL(for: id))
    store.record(.began(id, origin: .live, purpose: .type, at: start, app: app))
    store.record(.audioEnded(id, audio))
    store.record(.textReady(id, TextVersions(model: cleaned, cleaned: cleaned), cleanup: .rulesOnly(.off),
                            model: parakeet, typing: true))
    store.record(.delivered(id, receipt, lag: .milliseconds(420)))
    await store.flush()
    return id
}

/// A Re-speak Fix that replaces `before` with `after`, at `location` in the text as it stood, made `seconds` after the row started.
private func respeak(_ id: DictationID, _ before: String, _ after: String, at location: Int?, seconds: Double) -> Fix {
    Fix(dictation: id, kind: .respeak, source: .respeak, before: before, after: after, location: location,
        verdict: .proposed, at: start.addingTimeInterval(seconds))
}

private func finalText(_ store: HistoryStore, _ id: DictationID) async -> String? {
    await store.dictation(id)?.finalText
}

@Suite struct FixPositionTests {
    @Test func aLocatedFixEditsTheSecondOfTwoIdenticalWords() async throws {
        let (store, _) = try makeStore()
        let id = try await inserted(store, cleaned: "the cat saw the cat")
        store.record(.fixRecorded(respeak(id, "cat", "dog", at: 16, seconds: 5)))
        await store.flush()
        #expect(await finalText(store, id) == "the cat saw the dog")
    }

    @Test func aLocatedFixEditsTheFirstOfTwoIdenticalWordsWhenItsLocationSaysSo() async throws {
        let (store, _) = try makeStore()
        let id = try await inserted(store, cleaned: "the cat saw the cat")
        store.record(.fixRecorded(respeak(id, "cat", "dog", at: 4, seconds: 5)))
        await store.flush()
        #expect(await finalText(store, id) == "the dog saw the cat")
    }

    @Test func anUnlocatedFixStillEditsTheFirstOccurrence() async throws {
        let (store, _) = try makeStore()
        let id = try await inserted(store, cleaned: "the cat saw the cat")
        store.record(.fixRecorded(respeak(id, "cat", "dog", at: nil, seconds: 5)))
        await store.flush()
        #expect(await finalText(store, id) == "the dog saw the cat")
    }

    @Test func aLocatedFixFollowsItsWordWhenAnEarlierFixIsRejected() async throws {
        let (store, _) = try makeStore()
        let id = try await inserted(store, cleaned: "the cat saw the cat")
        let widen = respeak(id, "the", "a big", at: 0, seconds: 5)
        store.record(.fixRecorded(widen))
        store.record(.fixRecorded(respeak(id, "cat", "dog", at: 18, seconds: 6)))  // "a big cat saw the cat": the second cat is at 18
        await store.flush()
        #expect(await finalText(store, id) == "a big cat saw the dog")

        // Back to "the cat saw the cat": the second cat has moved to 16, and 18 no longer reads "cat".
        store.record(.fixVerdict(widen.id, .rejected))
        await store.flush()
        #expect(await finalText(store, id) == "the cat saw the dog")
    }

    @Test func aFixWhoseWordIsGoneChangesNothing() async throws {
        let (store, _) = try makeStore()
        let id = try await inserted(store, cleaned: "the cat saw the cat")
        store.record(.fixRecorded(respeak(id, "dog", "bird", at: 4, seconds: 5)))
        await store.flush()
        #expect(await finalText(store, id) == "the cat saw the cat")
    }

    @Test func aLocationCountsUTF16UnitsAfterAnEmoji() async throws {
        let (store, _) = try makeStore()
        // The emoji is two UTF-16 units and one Character, so the second "cat" starts at 19 (Character 18).
        let id = try await inserted(store, cleaned: "🎉 the cat saw the cat")
        store.record(.fixRecorded(respeak(id, "cat", "dog", at: 19, seconds: 5)))
        await store.flush()
        #expect(await finalText(store, id) == "🎉 the cat saw the dog")
    }

    @Test func aLocationCountsUTF16UnitsAfterADecomposedAccent() async throws {
        let (store, _) = try makeStore()
        // "e" plus a combining accent is two UTF-16 units and one Character, so the second "cat" starts at 22 (Character 21).
        let id = try await inserted(store, cleaned: "cafe\u{301} the cat saw the cat")
        store.record(.fixRecorded(respeak(id, "cat", "dog", at: 22, seconds: 5)))
        await store.flush()
        #expect(await finalText(store, id) == "cafe\u{301} the cat saw the dog")
    }

    @Test func aLocatedFixKeepsItsPlaceWhenTheStoreReopens() async throws {
        let (store, paths) = try makeStore()
        let id = try await inserted(store, cleaned: "the cat saw the cat")
        store.record(.fixRecorded(respeak(id, "cat", "dog", at: 16, seconds: 5)))
        await store.flush()
        #expect(await finalText(store, id) == "the cat saw the dog")

        // A new store on the same folder re-derives final text from every stored Fix when the next one lands.
        let reopened = try HistoryStore(paths: paths)
        reopened.record(.fixRecorded(respeak(id, "the", "a", at: 0, seconds: 6)))
        await reopened.flush()
        #expect(await finalText(reopened, id) == "a cat saw the dog")
    }
}
