import Foundation
import Testing
@testable import History
@testable import LexiconUI
import LexiconDomain

// The words the History window draws. The window itself (rows on screen, copy,
// close) is checked in the live-app lane: AppKit stays out of the test target.

private let parakeet = SpeechModel.local(.parakeetUnified)

@Test func dayHeadersSayTodayAndYesterdayAndAddTheYearOnlyWhenItDiffers() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 0, minute: 30)))
    func title(_ year: Int, _ month: Int, _ day: Int) -> String {
        HistoryText.title(for: DateComponents(year: year, month: month, day: day), now: now, calendar: calendar)
    }
    #expect(title(2026, 10, 11) == "Today")
    #expect(title(2026, 10, 10) == "Yesterday")
    #expect(title(2026, 10, 9) != "Yesterday")
    #expect(!title(2026, 10, 9).contains("2026"))
    #expect(title(2025, 10, 9).contains("2025"))
}

@Test func theGreyLineShowsModelLagAndAnyStatusWorthAWord() {
    func row(_ status: DictationStatus, cleanup: CleanupOutcome? = .rulesOnly(.off), model: SpeechModel? = parakeet,
             lag: Duration? = .milliseconds(612)) -> HistoryRow {
        HistoryRow(id: DictationID(), startedAt: Date(), finalText: "Text.", status: status, cleanup: cleanup, model: model,
                   lag: lag, pinned: false, hasAudio: true)
    }
    #expect(HistoryText.details(row(.inserted)) == "Parakeet (on this Mac) · 612 ms")
    #expect(HistoryText.details(row(.notInserted, lag: nil)) == "Parakeet (on this Mac) · not inserted")
    #expect(HistoryText.details(row(.recovered, cleanup: .rulesOnly(.rejected(.droppedContentWord)), lag: nil))
        == "Parakeet (on this Mac) · recovered · cleanup rejected")
    #expect(HistoryText.details(row(.waiting, cleanup: nil, model: nil, lag: nil)) == "waiting")
    #expect(HistoryText.details(row(.failed, cleanup: nil, model: nil, lag: nil)) == "failed")
}

@Test(arguments: DictationStatus.allCases)
func playAndRetryAreGreyedOutOnceTheAudioAgedOut(status: DictationStatus) {
    func row(audio: Bool, pinned: Bool = false) -> HistoryRow {
        HistoryRow(id: DictationID(), startedAt: Date(), finalText: "Text.", status: status, cleanup: nil, model: parakeet,
                   lag: nil, pinned: pinned, hasAudio: audio)
    }
    let agedOut = RowActions(row(audio: false), canWrite: true)
    #expect(!agedOut.play)
    #expect(!agedOut.retry)
    #expect(!agedOut.pin)  // nothing left to keep
    #expect(RowActions(row(audio: false, pinned: true), canWrite: true).pin)  // but a pin can always come off

    let kept = RowActions(row(audio: true), canWrite: true)
    #expect(kept.play == (status != .recording))
    #expect(kept.pin == !status.isInFlight)
    #expect(kept.retry == (!status.isInFlight && status != .waiting))  // a waiting one is retried already
    #expect(kept.delete == !status.isInFlight)  // never while recording, transcribing or ready
}

@Test func withoutTheRunningSystemOnlyPlayWorks() {
    let row = HistoryRow(id: DictationID(), startedAt: Date(), finalText: "Text.", status: .inserted, cleanup: nil,
                         model: parakeet, lag: nil, pinned: true, hasAudio: true)
    let actions = RowActions(row, canWrite: false)
    #expect(actions.play)
    #expect(!actions.pin && !actions.retry && !actions.delete)
}

@Test func aRowBeingRetriedCannotBeRetriedDeletedOrPinnedUntilItLands() {
    let row = HistoryRow(id: DictationID(), startedAt: Date(), finalText: "Text.", status: .failed, cleanup: nil,
                         model: parakeet, lag: nil, pinned: false, hasAudio: true)
    let actions = RowActions(row, canWrite: true, retrying: true)
    #expect(actions.play)
    #expect(!actions.retry && !actions.delete && !actions.pin)
}

@Test func showVersionsListsModelCleanedAndFinalTextThenAnyEngineThatLost() {
    let row = HistoryRow(id: DictationID(), startedAt: Date(), finalText: "Ship the useAuth hook.", status: .inserted,
                         cleanup: .rulesOnly(.rejected(.droppedContentWord)), model: parakeet, lag: nil, pinned: false,
                         hasAudio: true)
    let won = AttemptRecord(model: parakeet, result: .won, text: "ship the use auth hook", latency: .milliseconds(80),
                            error: nil)
    let lost = AttemptRecord(model: .cloud(.museVoice), result: .timedOut, text: nil, latency: nil, error: "no final")
    let detail = HistoryDetail(row: row, versions: TextVersions(model: "ship the use auth hook", cleaned: "Ship the use auth hook."),
                               attempts: [won, lost], earlier: [])

    let sections = HistoryText.versions(detail)
    #expect(sections.map(\.label) == ["Model: Parakeet (on this Mac)", "Cleaned (cleanup rejected)", "Final",
                                      "Meta Muse Voice: timed out"])
    #expect(sections.map(\.text) == ["ship the use auth hook", "Ship the use auth hook.", "Ship the useAuth hook.", "no final"])

    let failed = HistoryDetail(row: row, versions: nil, attempts: [], earlier: [])
    #expect(HistoryText.versions(failed).isEmpty)
}

@Test func eachEarlierVersionSaysWhenItWasReplacedAndWhoHeardItThenWhatAFixWasMadeOn() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.locale = Locale(identifier: "en_US")
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15)))
    let row = HistoryRow(id: DictationID(), startedAt: now, finalText: "Third.", status: .inserted, cleanup: nil,
                         model: parakeet, lag: nil, pinned: false, hasAudio: true)
    let fixed = EarlierVersion(cleaned: "Ship it to super base.", final: "Ship it to Supabase.", model: .cloud(.museVoice),
                               replacedAt: now.addingTimeInterval(-60))
    let plain = EarlierVersion(cleaned: "First.", final: "First.", model: parakeet,
                               replacedAt: now.addingTimeInterval(-86_400))
    let detail = HistoryDetail(row: row, versions: TextVersions(model: "third", cleaned: "Third."), attempts: [],
                               earlier: [fixed, plain])

    let sections = Array(HistoryText.versions(detail, now: now, calendar: calendar).dropFirst(3))
    #expect(sections.map(\.text) == ["Ship it to Supabase.", "Ship it to super base.", "First."])
    let labels = sections.map(\.label)
    try #require(labels.count == 3)
    // The clock's spacing before AM/PM is the locale's, so only the parts Lexicon writes are pinned.
    #expect(labels[0].hasPrefix("Replaced Today at 2:59") && labels[0].hasSuffix(" · Meta Muse Voice"))
    #expect(labels[1].hasPrefix("Replaced Today at 2:59") && labels[1].hasSuffix(" · Meta Muse Voice, before Fixes"))
    #expect(labels[2].hasPrefix("Replaced Yesterday at 3:00") && labels[2].hasSuffix(" · Parakeet (on this Mac)"))
}
