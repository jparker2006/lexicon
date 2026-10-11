import Testing
@testable import History
import LexiconDomain

// The status rules, written out by hand from #41 so the table in
// `DictationStatus.canMove` is checked against the spec, not against itself.
private let allowedMoves: [DictationStatus: Set<DictationStatus>] = [
    .recording: [.transcribing, .waiting, .failed, .notInserted, .recovered],
    .transcribing: [.ready, .waiting, .failed, .notInserted, .recovered],
    .waiting: [.ready, .failed, .notInserted, .recovered],
    .ready: [.inserted, .notInserted],
    .notInserted: [.inserted],
    .recovered: [.inserted],
    .failed: [.notInserted, .recovered],
    .inserted: [],
]

@Test(arguments: DictationStatus.allCases)
func everyStatusMoveFollowsTheRules(from: DictationStatus) {
    let allowed = allowedMoves[from]!
    for to in DictationStatus.allCases {
        #expect(from.canMove(to: to) == (to == from || allowed.contains(to)), "\(from) -> \(to)")
    }
}

@Test func replayedEventsCannotMoveStatusBackwards() {
    #expect(DictationStatus.notInserted.canMove(to: .inserted))
    #expect(!DictationStatus.inserted.canMove(to: .waiting))       // a late `.waiting` replay is a no-op
    #expect(DictationStatus.inserted.canMove(to: .inserted))       // same-state replay is allowed, changes nothing
    #expect(HistoryStore.admits(.recording, from: nil))
    #expect(!HistoryStore.admits(.transcribing, from: nil))
}

@Test func onlyBeganCreatesARow() {
    for status in DictationStatus.allCases {
        #expect(HistoryStore.admits(status, from: nil) == (status == .recording))
    }
}

@Test func statusSetsMatchTheSpec() {
    #expect(Set(DictationStatus.allCases.filter(\.isInFlight)) == [.recording, .transcribing, .ready])
    #expect(Set(DictationStatus.allCases.filter(\.needsAudio)) == [.recording, .transcribing, .waiting, .failed])
}

@Test func textThatIsNeverTypedLandsWithoutLosingItsStatus() {
    let receipt = InsertionReceipt(appBundleID: nil, fieldFingerprint: nil, caretAfter: nil,
                                   contextBefore: "", contextAfter: "", insertedAt: .now)
    #expect(DictationStatus.landed(.inserted(receipt), origin: .live, previous: .ready) == .inserted)
    #expect(DictationStatus.landed(.notInserted(.focusMoved), origin: .live, previous: .ready) == .notInserted)
    // Recovered audio is never typed, whatever came before.
    #expect(DictationStatus.landed(.historyOnly, origin: .recovered, previous: .transcribing) == .recovered)
    #expect(DictationStatus.landed(.historyOnly, origin: .recovered, previous: .failed) == .recovered)
    // A manual Retry keeps a row that already had text where it was.
    #expect(DictationStatus.landed(.historyOnly, origin: .live, previous: .inserted) == .inserted)
    #expect(DictationStatus.landed(.historyOnly, origin: .live, previous: .notInserted) == .notInserted)
    // A Retry of a failed or waiting row, or Re-speak audio, lands as not inserted.
    #expect(DictationStatus.landed(.historyOnly, origin: .live, previous: .failed) == .notInserted)
    #expect(DictationStatus.landed(.historyOnly, origin: .file, previous: .transcribing) == .notInserted)
    #expect(DictationStatus.landed(.historyOnly, origin: .live, previous: nil) == .notInserted)
    #expect(DictationStatus.afterTextReady(typing: true, origin: .live, previous: .transcribing) == .ready)
    #expect(DictationStatus.afterTextReady(typing: false, origin: .recovered, previous: .transcribing) == .recovered)
}

@Test func unfinishedIndexIsGeneratedFromTheEnum() {
    let unfinished = DictationStatus.allCases.filter { !$0.isTerminal }.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    #expect(HistorySchema.derivedIndexes[0].hasSuffix("(\(unfinished))"))
    #expect(HistorySchema.derivedIndexes[0].hasSuffix("('recording', 'transcribing', 'waiting', 'ready')"))
}

@Test func retentionSkipListIsGeneratedFromTheEnum() {
    let kept = DictationStatus.allCases.filter(\.needsAudio).map { "'\($0.rawValue)'" }.joined(separator: ", ")
    #expect(Retention.skippedStatuses == kept)
    #expect(Retention.skippedStatuses == "'recording', 'transcribing', 'waiting', 'failed'")
}
