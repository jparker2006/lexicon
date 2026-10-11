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
