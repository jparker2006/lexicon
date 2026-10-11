public import Foundation
public import LexiconDomain

/// Jev decisions (#12): TypeSafe direct `POST https://api.typesafe.ai/v1/systemone`,
/// model pinned `jev-1.13.0`, plain URLSession, one request per state with all
/// its questions, ~1 s budget, 429/529 retried at most twice.
///
/// Every decision REQUIRES a local fallback: `decide` has no overload without
/// one and never throws. Private mode (no `CloudAccess`), no key, timeout and
/// errors all return the fallback, marked as such. Plain dictation never awaits
/// this; only Fixes and close calls do, off the fn-up path. The key comes from
/// `access.key(.jev, sending: text)`, and only the words around a close call are
/// sent, not the whole Dictation (#5).
public struct JevClient: Sendable {
    public init(session: URLSession = .shared) { fatalError("not implemented") }

    /// fn-down: open the TLS connection so a later decision skips the cold start.
    public func prewarm(_ access: CloudAccess?) { fatalError("not implemented") }

    public func decide<Answer: Sendable>(
        _ question: JevQuestion<Answer>,
        access: CloudAccess?,
        budget: Duration = .seconds(1),
        fallback: Answer
    ) async -> Decision<Answer> {
        fatalError("not implemented")
    }
}

/// A typed question. Built only from the factories below, which own the prompt
/// wording; the TypeSafe wire shape stays internal to this module.
public struct JevQuestion<Answer: Sendable>: Sendable {
    let encode: @Sendable () -> Data
    let decode: @Sendable (Data) -> (Answer, probability: Double)?
}

extension JevQuestion where Answer == Bool {
    /// Hand fix filter (#13): recognition error (learn it) or a rewrite (don't)?
    public static func isRecognitionError(before: String, after: String, app: AppContext) -> JevQuestion<Bool> {
        fatalError("not implemented")
    }
}

extension JevQuestion where Answer == [Int: Bool] {
    /// Close calls (#10): for each flagged span, did the speaker mean the Lexicon term?
    /// Keys are indexes into `flagged`; true = use the term.
    public static func meantLexiconTerms(text: String, flagged: [(heard: String, term: String)],
                                         app: AppContext) -> JevQuestion<[Int: Bool]> {
        fatalError("not implemented")
    }
}

extension JevQuestion where Answer == Int? {
    /// Re-speak fix (M4): which candidate span did the re-spoken word replace?
    /// Text only (#12): phonetic hints computed on the Mac go in as text.
    public static func replacedSpan(previous: String, spoken: String, candidates: [String],
                                    phoneticHints: [String]) -> JevQuestion<Int?> {
        fatalError("not implemented")
    }
}

public struct Decision<Answer: Sendable>: Sendable {
    public let answer: Answer
    public let source: Source
    public enum Source: Sendable, Hashable {
        case jev(probability: Double)
        case fallback(Reason)
    }
    public enum Reason: String, Sendable, Hashable { case privateMode, noKey, timeout, error, lowConfidence }
}
