public import Foundation
public import LexiconDomain

/// Jev decisions: TypeSafe direct `POST https://api.typesafe.ai/v1/systemone`,
/// model pinned `jev-1.13.0`, plain URLSession, one request per state with all
/// its questions. Used for Re-speak fixes and Hand fixes only, never during
/// plain dictation: nothing on the fn-up path awaits this.
///
/// Every decision REQUIRES a local fallback: `decide` has no overload without
/// one and never throws. Private mode (no `CloudAccess`, or access revoked
/// mid-call), a Secret guard match, no key, the budget running out and errors
/// all return the fallback, marked with why. The key comes from
/// `access.key(.jev, sending:)`, so the Secret guard reads every word first.
public struct JevClient: Sendable {
    /// The Re-speak target is 0.5 s at p95 from release to the fix landing:
    /// speech final + Jev + replace. Jev warm measured p50 150 ms, p95 215 ms on
    /// Jake's Mac; 250 ms covers that p95 and leaves about 250 ms for the speech
    /// final (local Parakeet about 80 ms on a short clip) and the replace (about
    /// 12 ms in a native field). Past it, the fallback decides. No retries: a
    /// second round trip can't fit after a failed first one.
    public static let budget: Duration = .milliseconds(250)

    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-1.13.0"

    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// fn-down: open the TLS connection so a later decision skips the cold start
    /// (measured 359 ms cold vs 150 ms warm). A HEAD carries no text and isn't a
    /// model call; URLSession keeps the connection for the next request.
    public func prewarm(_ access: CloudAccess?) {
        guard let key = access?.key(.jev) else { return }
        let request = Self.request("HEAD", key: key, body: nil)
        let session = session
        Task { _ = try? await session.data(for: request) }
    }

    public func decide<Answer: Sendable>(
        _ question: JevQuestion<Answer>,
        access: CloudAccess?,
        budget: Duration = JevClient.budget,
        fallback: Answer
    ) async -> Decision<Answer> {
        let fallingBack: @Sendable (Decision<Answer>.Reason) -> Decision<Answer> = {
            Decision(answer: fallback, source: .fallback($0))
        }
        guard let access else { return fallingBack(.privateMode) }
        guard let key = access.key(.jev, sending: question.sent) else {
            return fallingBack(access.revoked.map(Decision<Answer>.Reason.init) ?? .noKey)
        }

        let request = Self.request("POST", key: key, body: question.body)
        let session = session

        // First to finish wins; the others are cancelled, which cancels the request.
        return await withTaskGroup(of: Decision<Answer>.self) { group in
            group.addTask {
                guard let (data, response) = try? await session.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let (answer, probability) = question.decode(data)
                else { return fallingBack(.error) }
                return Decision(answer: answer, source: .jev(probability: probability))
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return fallingBack(.timeout)
            }
            group.addTask {
                // Private mode turned on mid-call: drop the answer at once.
                guard let reason = await access.whenRevoked() else { return fallingBack(.timeout) }
                return fallingBack(.init(reason))
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    private static func request(_ method: String, key: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }
}

/// A typed question. Built only from the factories below, which own the prompt
/// wording; the TypeSafe wire shape stays internal to this module.
public struct JevQuestion<Answer: Sendable>: Sendable {
    /// Every piece of Jake's text in `body`, for the Secret guard.
    let sent: String
    /// The whole request body: model, state and every question about that state.
    let body: Data
    /// The answer and the probability Jev gave it, or nil for a reply that doesn't fit.
    let decode: @Sendable (Data) -> (Answer, probability: Double)?
}

extension JevQuestion where Answer == Bool {
    /// Hand fix filter (#13): recognition error (learn it) or a rewrite (don't)?
    public static func isRecognitionError(before: String, after: String, app: AppContext) -> JevQuestion<Bool> {
        fatalError("not implemented")
    }
}

/// One span of the recent text a Re-speak fix might replace.
public struct RespeakCandidate: Sendable, Hashable {
    /// Word indexes into the recent text (split on whitespace), 1 to 3 words.
    public let words: Range<Int>
    /// Phonetic code computed on the Mac: Jev reads text only.
    public let phonetic: String

    public init(words: Range<Int>, phonetic: String) {
        self.words = words
        self.phonetic = phonetic
    }
}

/// One of Jev's answers to a Re-speak question.
public struct RespeakPick: Sendable, Hashable {
    /// Index into the candidates passed in; nil means the re-spoken word replaces none of them.
    public let candidate: Int?
    public let probability: Double

    public init(candidate: Int?, probability: Double) {
        self.candidate = candidate
        self.probability = probability
    }
}

extension JevQuestion where Answer == [RespeakPick] {
    /// Words sent on each side of a candidate. A starting value, tuned on the Test set.
    static let contextWords = 3
    /// Candidates sent, best first by sound; the rest are dropped so the body stays
    /// a few small windows, never the whole Dictation.
    static let maxCandidates = 4

    /// Re-speak fix (M4): which candidate span did the re-spoken word replace?
    /// Sends only each candidate plus `contextWords` words either side of it,
    /// never the rest of `recent`. Candidates outside `recent` or longer than 3
    /// words are skipped. The answer lists every option, most likely first.
    public static func respeakTarget(spoken: String, spokenPhonetic: String, recent: String,
                                     candidates: [RespeakCandidate]) -> JevQuestion<[RespeakPick]> {
        let words = recent.split(whereSeparator: \.isWhitespace).map(String.init)
        let usable = candidates.enumerated().filter { _, candidate in
            !candidate.words.isEmpty && candidate.words.count <= 3
                && candidate.words.lowerBound >= 0 && candidate.words.upperBound <= words.count
        }.prefix(maxCandidates)

        var options: [String: Int] = [:]
        var state = RespeakState(respoken: spoken, respokenPhonetic: spokenPhonetic, candidates: [:])
        for (index, candidate) in usable {
            let span = candidate.words
            let option = "c\(options.count + 1)"
            options[option] = index
            state.candidates[option] = .init(
                before: words[max(0, span.lowerBound - contextWords)..<span.lowerBound].joined(separator: " "),
                text: words[span].joined(separator: " "),
                after: words[span.upperBound..<min(words.count, span.upperBound + contextWords)].joined(separator: " "),
                phonetic: candidate.phonetic)
        }

        var criteria: [String: String] = options.keys.reduce(into: [:]) { $0[$1] = "candidate \($1)" }
        criteria["none"] = "`respoken` does not replace any candidate"
        let target = WireQuestion(
            type: "choice",
            instructions: "Which candidate was the user correcting when they said `respoken`? Each candidate shows "
                + "the words before and after it. A correction usually sounds like the text it replaces: compare "
                + "`respoken_phonetic` with each candidate's `phonetic`.",
            criteria: criteria)

        let sent = ([spoken] + state.candidates.keys.sorted().flatMap { option in
            let c = state.candidates[option]!
            return [c.before, c.text, c.after]
        }).joined(separator: "\n")

        let candidateFor = options
        return JevQuestion(sent: sent, body: encode(state: state, questions: ["target": target])) { data in
            guard let answer = try? JSONDecoder().decode(WireResponse.self, from: data).answers["target"],
                  let probabilities = answer.probabilities
            else { return nil }
            let picks = probabilities.compactMap { option, p -> RespeakPick? in
                if option == "none" { return RespeakPick(candidate: nil, probability: p) }
                return candidateFor[option].map { RespeakPick(candidate: $0, probability: p) }
            }.sorted { $0.probability > $1.probability }
            guard let top = picks.first else { return nil }
            return (picks, top.probability)
        }
    }
}

/// An answer and where it came from: Jev, or the fallback and why.
public struct Decision<Answer: Sendable>: Sendable {
    public let answer: Answer
    public let source: Source
    public enum Source: Sendable, Hashable {
        case jev(probability: Double)
        case fallback(Reason)
    }
    public enum Reason: String, Sendable, Hashable {
        /// No access: Private mode, an always-private app, or turned on mid-call.
        case privateMode
        /// The Secret guard matched this Dictation's text; nothing was sent.
        case secretFound
        case noKey
        case timeout
        case error

        init(_ revoked: AccessRevoked) {
            switch revoked {
            case .privateModeOn, .alwaysPrivateApp: self = .privateMode
            case .secretFound: self = .secretFound
            }
        }
    }
}

// MARK: TypeSafe wire shape

private struct WireRequest<State: Encodable>: Encodable {
    let model: String
    let state: State
    let questions: [String: WireQuestion]
}

private struct WireQuestion: Encodable {
    /// `choice`, `noul` or `score`.
    let type: String
    let instructions: String
    let criteria: [String: String]?
}

private struct WireResponse: Decodable {
    struct Answer: Decodable {
        let probabilities: [String: Double]?
    }
    let answers: [String: Answer]
}

private struct RespeakState: Encodable {
    struct Candidate: Encodable {
        let before: String
        let text: String
        let after: String
        let phonetic: String
    }
    let respoken: String
    let respokenPhonetic: String
    var candidates: [String: Candidate]

    enum CodingKeys: String, CodingKey {
        case respoken, candidates
        case respokenPhonetic = "respoken_phonetic"
    }
}

private func encode<State: Encodable>(state: State, questions: [String: WireQuestion]) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    // Encoding plain strings and dictionaries can't fail.
    return try! encoder.encode(WireRequest(model: JevClient.model, state: state, questions: questions))
}
