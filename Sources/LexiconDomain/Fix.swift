public import Foundation

public struct FixID: Hashable, Sendable, Codable {
    public let uuid: UUID
    public init() { self.uuid = UUID() }
    public init(uuid: UUID) { self.uuid = uuid }
}

public enum FixKind: String, Sendable, Codable, CaseIterable {
    case respeak
    case hand
    /// A close call Jev settled after insertion (#10). Behaves like a Re-speak fix Jake didn't have to make.
    case auto
}

public enum FixSource: String, Sendable, Codable, CaseIterable {
    case axWatch
    case claudeCodeHook
    case codexHook
    case justFixedShortcut
    case respeak
    case closeCall
}

public enum FixVerdict: String, Sendable, Codable, CaseIterable {
    /// Seen, filtered, recorded. Changes final text. Not yet a Rule.
    case proposed
    /// Jake said "always fix this way": became a Rule and a Test set entry.
    case confirmed
    case rejected
    /// An edit that is a rewrite, not a recognition error. Changes final text, never a Rule.
    case rewrite
}

/// A correction to one Dictation's text. Recorded through History only.
/// Idempotent by `id`: observing the same Fix twice records it once.
public struct Fix: Sendable, Hashable, Codable {
    public var id: FixID
    public var dictation: DictationID
    public var kind: FixKind
    public var source: FixSource
    public var before: String
    public var after: String
    public var verdict: FixVerdict
    public var at: Date
    public init(id: FixID = FixID(), dictation: DictationID, kind: FixKind, source: FixSource,
                before: String, after: String, verdict: FixVerdict, at: Date) {
        self.id = id
        self.dictation = dictation
        self.kind = kind
        self.source = source
        self.before = before
        self.after = after
        self.verdict = verdict
        self.at = at
    }
}
