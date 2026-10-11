import Foundation

/// One entry in the Lexicon: a name, a code term, a phrase.
public struct Term: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case name, code, phrase }
    public var text: String
    public var kind: Kind
    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }
}

/// "When you hear X, write Y", created from a Fix Jake confirmed.
public struct Rule: Sendable, Hashable, Codable {
    public var heard: String
    public var written: String
    public init(heard: String, written: String) {
        self.heard = heard
        self.written = written
    }
}

/// Rules compiled for one Dictation. Immutable snapshot taken at fn-down, so a
/// Rule added mid-Dictation never changes text already being produced.
/// Matching semantics live here and only here: whole words, case-insensitive
/// match, written form copied exactly.
public struct RuleSet: Sendable {
    public static let empty = RuleSet([])
    // TODO: compile into a trie or a hash map keyed by the first word of `heard`.
    let rules: [Rule]
    public init(_ rules: [Rule]) { self.rules = rules }
    public var isEmpty: Bool { rules.isEmpty }

    /// Pure, microseconds. Applies every Rule once, longest `heard` first.
    public func apply(to text: String) -> String {
        // TODO: tokenize on word boundaries; at each token try the longest Rule whose
        // `heard` words match case-insensitively; emit `written`; never re-scan output.
        fatalError("not implemented")
    }
}

/// What Lexicon knows about where Jake is dictating. Gathered at fn-down from
/// the frontmost app (no screenshots, ever: D5).
public struct AppContext: Sendable, Hashable, Codable {
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    /// Current project, when known (Claude Code hook `cwd`, terminal title). #21 decides more.
    public var workingDirectory: String?
    public init(bundleID: String?, appName: String?, windowTitle: String?, workingDirectory: String?) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.workingDirectory = workingDirectory
    }
    public static let unknown = AppContext(bundleID: nil, appName: nil, windowTitle: nil, workingDirectory: nil)
}
