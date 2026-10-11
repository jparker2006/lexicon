import Foundation
import Synchronization
import Testing
@testable import Jev
import LexiconDomain

// A fake TypeSafe server behind URLProtocol: the real URLSession, request and
// response decoding, with no network. Fake keys only. Each fake's session tags
// its requests, so tests run in parallel without seeing each other's.

private final class FakeJev: Sendable {
    struct Request: Sendable {
        let method: String?
        let url: URL?
        let headers: [String: String]
        let body: Data
    }

    /// nil: the request hangs until the client cancels it.
    typealias Reply = @Sendable (Data) -> (status: Int, body: Data)?

    static let servers = Mutex<[String: FakeJev]>([:])

    let key = "fake-jev-key-" + UUID().uuidString
    let reply: Reply
    private let received = Mutex<[Request]>([])
    private let arrivals: AsyncStream<Void>.Continuation
    let arrived: AsyncStream<Void>

    init(reply: @escaping Reply) {
        self.reply = reply
        (arrived, arrivals) = AsyncStream<Void>.makeStream()
        Self.servers.withLock { $0[key] = self }
    }

    var requests: [Request] { received.withLock { $0 } }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeJevProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fake-Jev": key]
        return URLSession(configuration: configuration)
    }

    func access(_ preferences: Preferences = .defaults) -> CloudAccess? {
        let key = key
        return CloudAccess.granted(by: preferences, for: .app(.unknown)) { $0 == .jev ? key : nil }
    }

    func receive(_ request: Request) -> (status: Int, body: Data)? {
        received.withLock { $0.append(request) }
        arrivals.yield()
        return request.method == "HEAD" ? (405, Data()) : reply(request.body)
    }
}

/// `@unchecked Sendable`: URLProtocol is an Objective-C class URLSession drives
/// from its own queue; this subclass adds no state of its own.
private final class FakeJevProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let tag = request.value(forHTTPHeaderField: "X-Fake-Jev") ?? ""
        guard let server = FakeJev.servers.withLock({ $0[tag] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let received = FakeJev.Request(method: request.httpMethod, url: request.url,
                                       headers: request.allHTTPHeaderFields ?? [:], body: bodyData())
        guard let (status, body) = server.receive(received) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not `httpBody`.
    private func bodyData() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private func answer(_ probabilities: [String: Double]) -> Data {
    let json: [String: Any] = [
        "model": "jev-1.13.0",
        "answers": ["target": ["type": "choice", "choice": probabilities.max { $0.value < $1.value }!.key,
                               "probabilities": probabilities, "confidence": 0.9]],
        "usage": ["input_tokens": 300, "output_tokens": 20],
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private let recent = "okay now wire the auth callback into super base and then redeploy to vercel"
private let superBase = RespeakCandidate(words: 7..<9, phonetic: "SPRBS")
private let callback = RespeakCandidate(words: 5..<6, phonetic: "KLBK")
private let question = JevQuestion.respeakTarget(spoken: "Supabase", spokenPhonetic: "SPBS", recent: recent,
                                                 candidates: [callback, superBase])!
/// The caller's own ranking by sound, used when Jev can't answer.
private let soundRanking = [RespeakPick(candidate: 1, probability: 0.6), RespeakPick(candidate: 0, probability: 0.3)]
/// Long enough that only a hang reaches it, so no test depends on machine speed.
private let generous: Duration = .seconds(60)

@Test func jevAnswersWithEveryCandidateRankedAndItsProbability() async throws {
    let server = FakeJev { _ in (200, answer(["c1": 0.02, "c2": 0.97, "none": 0.01])) }
    let decision = await JevClient(session: server.session)
        .decide(question, access: server.access(), budget: generous, fallback: soundRanking)

    #expect(decision.source == .jev(probability: 0.97))
    #expect(decision.answer == [
        RespeakPick(candidate: 1, probability: 0.97), RespeakPick(candidate: 0, probability: 0.02),
        RespeakPick(candidate: nil, probability: 0.01),
    ])

    let request = try #require(server.requests.only)
    #expect(request.method == "POST")
    #expect(request.url == URL(string: "https://api.typesafe.ai/v1/systemone"))
    #expect(request.headers["Authorization"] == "Bearer " + server.key)
    #expect(request.headers["Content-Type"] == "application/json")
    let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    #expect(body["model"] as? String == "jev-1.13.0")
    // All questions about one state go in this one request.
    #expect((body["questions"] as? [String: Any])?.keys.sorted() == ["target"])
}

@Test func pastTheBudgetTheFallbackDecides() async {
    let server = FakeJev { _ in nil }
    let decision = await JevClient(session: server.session)
        .decide(question, access: server.access(), budget: .milliseconds(50), fallback: soundRanking)
    #expect(decision.source == .fallback(.timeout))
    #expect(decision.answer == soundRanking)
}

@Test func privateModeDecidesLocallyWithNoRequest() async {
    let server = FakeJev { _ in (200, answer(["c1": 1])) }
    var privateMode = Preferences.defaults
    privateMode.privacy = .private
    let client = JevClient(session: server.session)

    client.prewarm(server.access(privateMode))
    let decision = await client.decide(question, access: server.access(privateMode), budget: generous,
                                       fallback: soundRanking)
    #expect(decision.source == .fallback(.privateMode))
    #expect(decision.answer == soundRanking)
    #expect(server.requests.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func privateModeTurnedOnMidCallDropsTheAnswerAtOnce() async {
    let server = FakeJev { _ in nil }
    let access = server.access()
    let deciding = Task {
        await JevClient(session: server.session).decide(question, access: access, budget: generous,
                                                         fallback: soundRanking)
    }
    for await _ in server.arrived { break }
    access?.revoke(.privateModeOn)
    #expect(await deciding.value.source == .fallback(.privateMode))
}

@Test func aCallerThatGaveUpStillGetsTheFallbackWithoutWaiting() async {
    let server = FakeJev { _ in nil }
    let deciding = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await JevClient(session: server.session).decide(question, access: server.access(), budget: generous,
                                                                fallback: soundRanking)
    }
    let decision = await deciding.value
    #expect(decision.answer == soundRanking)
    guard case .fallback = decision.source else { Issue.record("answered after the caller gave up"); return }
}

@Test func aSecretInTheWordsSendsNothing() async throws {
    let server = FakeJev { _ in (200, answer(["c1": 1])) }
    let access = server.access()
    let secret = "ghp_" + "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xY2zA4"
    let leaky = try #require(JevQuestion.respeakTarget(
        spoken: "Supabase", spokenPhonetic: "SPBS", recent: "use \(secret) here",
        candidates: [RespeakCandidate(words: 2..<3, phonetic: "HR")]))
    let decision = await JevClient(session: server.session)
        .decide(leaky, access: access, budget: generous, fallback: [])
    #expect(decision.source == .fallback(.secretFound))
    #expect(access?.revoked == .secretFound)
    #expect(server.requests.isEmpty)
}

@Test func noKeyOrABadReplyFallsBack() async {
    let noKey = await JevClient()
        .decide(question, access: CloudAccess.granted(by: .defaults, for: .app(.unknown)) { _ in nil }, fallback: soundRanking)
    #expect(noKey.source == .fallback(.noKey))

    for reply in [(500, answer(["c1": 1])), (200, Data("not json".utf8)), (200, answer(["unknown": 1]))] {
        let server = FakeJev { _ in reply }
        let decision = await JevClient(session: server.session)
            .decide(question, access: server.access(), budget: generous, fallback: soundRanking)
        #expect(decision.source == .fallback(.error))
        #expect(decision.answer == soundRanking)
    }
}

@Test(.timeLimit(.minutes(1))) func prewarmOpensTheConnectionWithoutTextOrKey() async throws {
    let server = FakeJev { _ in nil }
    JevClient(session: server.session).prewarm(server.access())
    for await _ in server.arrived { break }
    let request = try #require(server.requests.only)
    #expect(request.method == "HEAD")
    #expect(request.body.isEmpty)
    #expect(request.headers["Authorization"] == nil)
}

@Test func withNoCandidateLeftThereIsNothingToAsk() {
    let outside = [RespeakCandidate(words: 20..<21, phonetic: "A"), RespeakCandidate(words: 0..<4, phonetic: "B")]
    #expect(JevQuestion.respeakTarget(spoken: "Supabase", spokenPhonetic: "SPBS", recent: recent,
                                      candidates: outside) == nil)
    #expect(JevQuestion.respeakTarget(spoken: "Supabase", spokenPhonetic: "SPBS", recent: "",
                                      candidates: [superBase]) == nil)
}

@Test func tiedAnswersKeepTheCandidateOrder() async {
    let server = FakeJev { _ in (200, answer(["none": 0.4, "c2": 0.3, "c1": 0.3])) }
    let decision = await JevClient(session: server.session)
        .decide(question, access: server.access(), budget: generous, fallback: soundRanking)
    #expect(decision.answer.map(\.candidate) == [nil, 0, 1])
}

@Test func requestBodiesHoldOnlyTheWordsAroundEachCandidate() async throws {
    // 40 distinct words, so any word in the body says where in the Dictation it came from.
    let words = (0..<40).map { String(format: "word%02d", $0) }
    let candidates = [
        RespeakCandidate(words: 20..<22, phonetic: "A"),
        RespeakCandidate(words: 38..<41, phonetic: "B"),  // past the end: skipped
        RespeakCandidate(words: 0..<1, phonetic: "C"),
        RespeakCandidate(words: 10..<14, phonetic: "D"),  // 4 words: skipped
        RespeakCandidate(words: 39..<40, phonetic: "E"),
        RespeakCandidate(words: 30..<31, phonetic: "F"),
        RespeakCandidate(words: 6..<7, phonetic: "G"),  // past the candidate cap: not sent
    ]
    let server = FakeJev { _ in (200, answer(["c1": 1])) }
    let question = try #require(JevQuestion.respeakTarget(
        spoken: "word99", spokenPhonetic: "X", recent: words.joined(separator: " "), candidates: candidates))
    _ = await JevClient(session: server.session).decide(question, access: server.access(), budget: generous,
                                                        fallback: [])

    let request = try #require(server.requests.only)
    let body = try #require(String(data: request.body, encoding: .utf8))
    let context = JevQuestion<[RespeakPick]>.contextWords
    let sent = candidates.filter { $0.words.count <= 3 && $0.words.upperBound <= words.count }
        .prefix(JevQuestion<[RespeakPick]>.maxCandidates)
    let window = Set(sent.flatMap { max(0, $0.words.lowerBound - context)..<min(40, $0.words.upperBound + context) })
    for (i, word) in words.enumerated() {
        #expect(body.contains(word) == window.contains(i), "\(word)")
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
