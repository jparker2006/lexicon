public import Foundation
public import LexiconDomain
import Synchronization

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
    /// Times the budget. Tests pass a fake one, so no test races a real budget.
    private let clock: any Clock<Duration>
    /// URLSession's own limit on a request, in seconds.
    private let requestTimeout: TimeInterval

    public init(session: URLSession = .shared, clock: any Clock<Duration> = ContinuousClock()) {
        self.init(session: session, clock: clock, requestTimeout: 5)
    }

    init(session: URLSession, clock: any Clock<Duration>, requestTimeout: TimeInterval) {
        self.session = session
        self.clock = clock
        self.requestTimeout = requestTimeout
    }

    /// A Re-speak's fn-down (and, from M5, a Hand fix watch): open the TLS
    /// connection so the decision skips the cold start (measured 359 ms cold vs
    /// 150 ms warm). Never for plain dictation, which sends Jev nothing. A HEAD with no text and no key: the
    /// rejection still leaves URLSession a warm connection for the next request,
    /// and keys are never read at fn-down (a first Keychain read can wait on a prompt).
    public func prewarm(_ access: CloudAccess?) {
        guard let access, access.revoked == nil else { return }
        let session = session
        let request = request("HEAD", key: nil, body: nil)
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

        let clock = clock
        let race = FirstAnswer<Decision<Answer>>()
        return await withTaskCancellationHandler {
            await race.run { answer in [
                Task {
                    // The key read runs inside the budget: the first one can wait on a Keychain prompt.
                    guard let key = access.key(.jev, sending: question.sent) else {
                        return answer(fallingBack(access.revoked.map(Decision<Answer>.Reason.init) ?? .noKey))
                    }
                    answer(await self.ask(question, key: key, fallingBack: fallingBack))
                },
                Task {
                    guard (try? await clock.sleep(for: budget)) != nil else { return }
                    answer(fallingBack(.timeout))
                },
                Task {
                    // Private mode turned on mid-call: drop the answer at once.
                    if let reason = await access.whenRevoked() { answer(fallingBack(.init(reason))) }
                },
            ] }
        } onCancel: {
            race.answer(fallingBack(.cancelled))
        }
    }

    private func ask<Answer: Sendable>(
        _ question: JevQuestion<Answer>, key: String,
        fallingBack: (Decision<Answer>.Reason) -> Decision<Answer>
    ) async -> Decision<Answer> {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request("POST", key: key, body: question.body))
        } catch let error as URLError where error.code == .timedOut {
            // URLSession's own limit: the answer came too late, as past the
            // budget. A budget timer starved that long must not make it an error.
            return fallingBack(.timeout)
        } catch {
            return fallingBack(.error)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let (answer, probability) = question.decode(data)
        else { return fallingBack(.error) }
        return Decision(answer: answer, source: .jev(probability: probability))
    }

    private func request(_ method: String, key: String?, body: Data?) -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: requestTimeout)
        request.httpMethod = method
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }
}

/// The first of a few racing tasks to answer wins; the others are cancelled.
/// Unlike a task group it never waits for the losers, so one stuck where
/// cancelling can't reach (a Keychain read) can't hold the caller.
private final class FirstAnswer<Value: Sendable>: Sendable {
    private struct State {
        var answer: Value?
        var waiter: CheckedContinuation<Value, Never>?
        var racers: [Task<Void, Never>] = []
    }
    private let state = Mutex(State())

    /// Starts the racers, each handed `answer`, and returns the first answer.
    /// Starts none when an answer came first (a caller that already gave up).
    func run(_ racers: (@escaping @Sendable (Value) -> Void) -> [Task<Void, Never>]) async -> Value {
        await withCheckedContinuation { waiter in
            let early = state.withLock { state -> Value? in
                if state.answer == nil { state.waiter = waiter }
                return state.answer
            }
            if let early { return waiter.resume(returning: early) }
            let started = racers { self.answer($0) }
            let late = state.withLock { state -> Bool in
                if state.answer == nil { state.racers = started }
                return state.answer != nil
            }
            if late { started.forEach { $0.cancel() } }
        }
    }

    /// The first call wins; later ones are ignored.
    func answer(_ value: Value) {
        let (waiter, losers) = state.withLock { state -> (CheckedContinuation<Value, Never>?, [Task<Void, Never>]) in
            guard state.answer == nil else { return (nil, []) }
            state.answer = value
            defer { (state.waiter, state.racers) = (nil, []) }
            return (state.waiter, state.racers)
        }
        losers.forEach { $0.cancel() }
        waiter?.resume(returning: value)
    }
}

/// A typed question. Built only from the factories below, which own the prompt
/// wording; the TypeSafe wire shape stays internal to this module.
public struct JevQuestion<Answer: Sendable>: Sendable {
    /// Every string in `body` that came from the caller, for the Secret guard.
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
    /// words are skipped; nil when none is left, so there is nothing to ask.
    /// The answer lists every option, most likely first, ties in candidate order.
    public static func respeakTarget(spoken: String, spokenPhonetic: String, recent: String,
                                     candidates: [RespeakCandidate]) -> JevQuestion<[RespeakPick]>? {
        let words = recent.split(whereSeparator: \.isWhitespace).map(String.init)
        let usable = candidates.enumerated().filter { _, candidate in
            !candidate.words.isEmpty && candidate.words.count <= 3
                && candidate.words.lowerBound >= 0 && candidate.words.upperBound <= words.count
        }.prefix(maxCandidates)
        if usable.isEmpty { return nil }

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

        let sent = ([spoken, spokenPhonetic] + state.candidates.keys.sorted().flatMap { option in
            let c = state.candidates[option]!
            return [c.before, c.text, c.after, c.phonetic]
        }).joined(separator: "\n")

        let candidateFor = options
        return JevQuestion(sent: sent, body: encode(state: state, questions: ["target": target])) { data in
            guard let answer = try? JSONDecoder().decode(WireResponse.self, from: data).answers["target"],
                  let probabilities = answer.probabilities
            else { return nil }
            let picks = probabilities.compactMap { option, p -> RespeakPick? in
                if option == "none" { return RespeakPick(candidate: nil, probability: p) }
                return candidateFor[option].map { RespeakPick(candidate: $0, probability: p) }
            }.sorted { a, b in
                if a.probability != b.probability { return a.probability > b.probability }
                return (a.candidate ?? .max) < (b.candidate ?? .max)
            }
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
        /// The caller gave up, so nobody waits for the answer.
        case cancelled

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
