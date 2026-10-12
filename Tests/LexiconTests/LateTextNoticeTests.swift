import Foundation
import Testing
@testable import AudioCapture
@testable import LexiconCore
import AppText
import Cleanup
import History
import LexiconDomain
import Transcription
import WordStore

// Text that cannot be typed is never lost (#60): it stays in History as not
// inserted, with the reason, and Jake is told it is ready to paste-last.
// Headless: the real Conductor on a WAV, a destination that refuses or has no field.

private let spokenText = "Um, so can you, uh, refactor the useAuth hook so it it doesn't re-render on every keystroke?"
private let cleanedText = "Can you refactor the useAuth hook so it doesn't re-render on every keystroke?"

/// Answers every insert with `answer` and counts the inserts it was asked for.
/// With `hasTarget` false there is no focused field, so `target()` is nil and
/// the Conductor never asks it to insert.
private actor RefusingDestination: TextDestination {
    struct Target: Sendable {}
    let answer: Delivery
    let hasTarget: Bool
    private(set) var insertCalls = 0

    init(answer: Delivery, hasTarget: Bool = true) {
        self.answer = answer
        self.hasTarget = hasTarget
    }

    func context() -> AppContext { .unknown }
    func appChanges() -> AsyncStream<AppContext> { AsyncStream { $0.yield(.unknown) } }
    func target() -> Target? { hasTarget ? Target() : nil }
    func insert(_ text: String, for id: DictationID, at target: Target) -> Delivery {
        insertCalls += 1
        return answer
    }
}

private func makeConductor(_ destination: RefusingDestination) throws -> (Conductor<RefusingDestination>, HistoryStore) {
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let conductor = Conductor(
        recorder: Recorder(), speech: SpeechEngine(local: ScriptedTranscriber(text: spokenText), clock: TestClock()),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history, destination: destination,
        preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
        keyboard: nil, fixes: nil, jev: nil)
    return (conductor, history)
}

@Test(.timeLimit(.minutes(1)), arguments: [NotInsertedReason.focusMoved, .typedSince, .noField, .pasteFailed])
func aRefusedInsertKeepsItsTextNotInsertedWithTheReasonAndShowsReadyToPaste(_ reason: NotInsertedReason) async throws {
    let wav = try writeWAV(syntheticSamples(count: 19_200), rate: 16_000, in: try scratchDirectory())
    let destination = RefusingDestination(answer: .notInserted(reason))
    let (conductor, history) = try makeConductor(destination)
    let events = await conductor.events()

    let result = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    await history.flush()

    #expect(result.status == .notInserted)
    #expect(await destination.insertCalls == 1)
    let row = try #require(await history.dictation(result.id))
    #expect(row.status == .notInserted)
    #expect(row.finalText == cleanedText)
    #expect(try await statusReason(history, result.id) == reason.rawValue)

    var notices: [Notice] = []
    var finished: DictationStatus?
    for await event in events {
        if case .notice(let notice) = event { notices.append(notice) }
        if case .finished(_, let status) = event { finished = status; break }
    }
    #expect(notices.contains(.readyToPaste(result.id)))  // before .finished: the loop stops at it
    #expect(finished == .notInserted)
}

@Test(.timeLimit(.minutes(1)))
func withNowhereToTypeTheTextIsKeptNotInsertedAndTheInsertIsNeverCalled() async throws {
    let wav = try writeWAV(syntheticSamples(count: 19_200), rate: 16_000, in: try scratchDirectory())
    // The answer is never used: there is no field to insert into.
    let destination = RefusingDestination(answer: .notInserted(.noField), hasTarget: false)
    let (conductor, history) = try makeConductor(destination)

    let result = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    await history.flush()

    #expect(await destination.insertCalls == 0)
    let row = try #require(await history.dictation(result.id))
    #expect(row.status == .notInserted)
    #expect(row.finalText == cleanedText)
}
