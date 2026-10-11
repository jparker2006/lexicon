import AppKit
import AVFAudio
import LexiconDomain
import History
import LexiconCore

/// The History window: one view-based NSTableView. Day headers are group rows.
/// The table asks only for rows on screen; the data source maps a flat row
/// index to (day section, offset) and fetches pages of 50 from `HistoryReader`.
///
/// Row: time, full final text, grey line (model, lag, status for waiting /
/// recovered / not inserted / failed), icons: play (AVAudioPlayer), copy,
/// Test-set pin, ⋯ (Retry with model picker built from `SpeechModel.allCases`,
/// Show versions, Delete). Click a row copies the final text. Search field
/// filters with a plain-text match.
@MainActor
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let reader: HistoryReader
    let commands: HistoryCommands
    var sections: [DaySection] = []
    var player: AVAudioPlayer?

    init(reader: HistoryReader, commands: HistoryCommands) { fatalError("not implemented") }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func numberOfRows(in tableView: NSTableView) -> Int { fatalError("not implemented") }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { fatalError("not implemented") }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        fatalError("not implemented")
    }

    /// Closing drops the controller, the reader and its connection.
    func windowWillClose(_ notification: Notification) { fatalError("not implemented") }

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
        case .cancelled: "cancelled"
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

/// What the History window may ask for. Closures over the system, so the window
/// never holds the Conductor or the store directly.
struct HistoryCommands {
    let retry: @MainActor (DictationID, SpeechModel?) -> Void
    let setPinned: @MainActor (DictationID, Bool) -> Void
    let delete: @MainActor (DictationID) -> Void
}

/// Settings: Private mode, cloud model, local model (install / remove), mic,
/// API keys (Keychain), start at login. NSGridView of plain controls. Layout is fog.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(preferences: PreferencesStore, secrets: Secrets) { fatalError("not implemented") }
    required init?(coder: NSCoder) { fatalError("not implemented") }
}
