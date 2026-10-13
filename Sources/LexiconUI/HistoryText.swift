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

    /// Show Versions: what the model heard, what Cleanup made of it, and the final
    /// text after Fixes; then what each Retry replaced, newest first; then any engine
    /// that lost or failed. Empty with no text yet.
    static func versions(_ detail: HistoryDetail, now: Date = Date(),
                         calendar: Calendar = .current) -> [(label: String, text: String)] {
        var sections: [(label: String, text: String)] = []
        if let versions = detail.versions {
            let cleanup = detail.row.cleanup.flatMap(label(for:)).map { " (\($0))" } ?? ""
            sections = [
                ("Model" + (detail.row.model.map { ": \($0.displayName)" } ?? ""), versions.model),
                ("Cleaned" + cleanup, versions.cleaned),
                ("Final", detail.row.finalText ?? versions.cleaned),
            ]
        }
        let time = Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
                                    timeZone: calendar.timeZone).hour().minute()
        for earlier in detail.earlier {
            let day = title(for: calendar.dateComponents([.year, .month, .day], from: earlier.replacedAt), now: now,
                            calendar: calendar)
            let heard = earlier.model.map { " · \($0.displayName)" } ?? ""
            sections.append(("Replaced \(day) at \(earlier.replacedAt.formatted(time))\(heard)", earlier.final))
            // The text a Fix was made on, when one changed it.
            if earlier.cleaned != earlier.final { sections.append(("Before Fixes", earlier.cleaned)) }
        }
        for attempt in detail.attempts where attempt.result != .won {
            sections.append(("\(attempt.model.displayName): \(label(for: attempt.result))", attempt.text ?? attempt.error ?? ""))
        }
        return sections
    }

    /// Exhaustive: a new result fails the build here.
    static func label(for result: AttemptRecord.Result) -> String {
        switch result {
        case .won: "won"
        case .lost: "lost"
        case .failed: "failed"
        case .timedOut: "timed out"
        case .cancelled: "cancelled"
        }
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
