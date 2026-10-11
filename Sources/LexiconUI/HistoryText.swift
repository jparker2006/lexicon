import Foundation
import LexiconDomain
import History

/// The words the History window draws, apart from AppKit so tests can read them.
enum HistoryText {
    /// "Today", "Yesterday", "Friday, October 9", and the year once it is not this year's.
    static func title(for day: DateComponents, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = calendar.date(from: day) else { return "" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide).month(.wide).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }

    /// The grey line: model, lag, then any status or Cleanup outcome worth a word.
    static func details(_ row: HistoryRow) -> String {
        [
            row.model?.displayName,
            row.lag.map { "\(Int(($0 / .milliseconds(1)).rounded())) ms" },
            label(for: row.status),
            row.cleanup.flatMap(label(for:)),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// Status text is an exhaustive switch: a new DictationStatus fails the build here.
    static func label(for status: DictationStatus) -> String? {
        switch status {
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .waiting: "waiting"
        case .inserted: nil
        case .ready: "pasting"
        case .notInserted: "not inserted"
        case .recovered: "recovered"
        case .failed: "failed"
        }
    }

    /// Cleanup's part of the grey line. Exhaustive: a new reason fails the build here.
    static func label(for cleanup: CleanupOutcome) -> String? {
        switch cleanup {
        case .aiAccepted: nil
        case .rulesOnly(.off): nil
        case .rulesOnly(.rejected): "cleanup rejected"
        case .rulesOnly(.deadline): "cleanup late"
        case .rulesOnly(.unavailable): "cleanup unavailable"
        }
    }
}
