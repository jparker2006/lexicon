import Foundation
import LexiconDomain
import SQLiteKit

// How History's values sit in SQLite columns. Enum columns hold the Swift
// rawValue; times are unix milliseconds; durations are milliseconds.

extension Date {
    var unixMs: Int64 { Int64((timeIntervalSince1970 * 1_000).rounded()) }
    init(unixMs: Int64) { self.init(timeIntervalSince1970: Double(unixMs) / 1_000) }
}

extension Duration {
    var ms: Int64 { components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000 }
}

extension SQLValue {
    static func optional(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    static func optional(_ value: Int64?) -> SQLValue { value.map(SQLValue.int) ?? .null }
}

extension DictationID {
    init?(column: String) {
        guard let uuid = UUID(uuidString: column) else { return nil }
        self.init(uuid: uuid)
    }
}

extension DictationPurpose {
    /// `purpose`; the Dictation a Re-speak fixes goes in `respeak_of`.
    var column: String {
        switch self {
        case .type: "type"
        case .respeak: "respeak"
        }
    }
}

extension CleanupOutcome {
    /// JSON with sorted keys, so the same outcome is always the same text (replays compare equal).
    func column() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    init?(column: String) {
        guard let outcome = try? JSONDecoder().decode(CleanupOutcome.self, from: Data(column.utf8)) else { return nil }
        self = outcome
    }
}

extension DictationRecord {
    /// The columns `init(row:)` reads, in order.
    static let columns = """
        id, started_at, origin, purpose, respeak_of, status, model_text, cleaned_text, final_text, \
        cleanup, model, lag_ms, app_bundle_id, app_title, pinned, audio_storage
        """

    /// nil for a row a newer build wrote with a status or origin this build does not know.
    init?(row: Row) {
        guard let id = row.text(0).flatMap(DictationID.init(column:)),
              let origin = row.text(2).flatMap(DictationOrigin.init(rawValue:)),
              let status = row.text(5).flatMap(DictationStatus.init(rawValue:)) else { return nil }
        // A Re-speak whose Dictation was deleted has no target left (respeak_of went NULL), so it reads as `.type`.
        let purpose: DictationPurpose = if row.text(3) == DictationPurpose.respeak(of: id).column, let of = row.text(4).flatMap(DictationID.init(column:)) {
            .respeak(of: of)
        } else {
            .type
        }
        var versions: TextVersions?
        if let model = row.text(6), let cleaned = row.text(7) { versions = TextVersions(model: model, cleaned: cleaned) }
        self.init(
            id: id,
            startedAt: Date(unixMs: row.int(1) ?? 0),
            origin: origin,
            purpose: purpose,
            status: status,
            versions: versions,
            finalText: row.text(8),
            cleanup: row.text(9).flatMap(CleanupOutcome.init(column:)),
            model: row.text(10).flatMap(SpeechModel.init(id:)),
            lag: row.int(11).map { .milliseconds($0) },
            app: AppContext(bundleID: row.text(12), appName: row.text(13), windowTitle: nil, workingDirectory: nil),
            pinned: row.int(14) == 1,
            audio: row.text(15).flatMap(AudioStorage.init(rawValue:)) ?? .deleted
        )
    }
}
