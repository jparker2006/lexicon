import Foundation
import Synchronization
import Testing
@testable import Jev
import LexiconDomain

private let recent = "okay now wire the auth callback into super base and then redeploy to vercel"
private let superBase = RespeakCandidate(words: 7..<9, phonetic: "SPRBS")
private let callback = RespeakCandidate(words: 5..<6, phonetic: "KLBK")
private let question = JevQuestion.respeakTarget(spoken: "Supabase", spokenPhonetic: "SPBS", recent: recent,
                                                 candidates: [callback, superBase])!
/// The caller's own ranking by sound, used when Jev can't answer.
private let soundRanking = [RespeakPick(candidate: 1, probability: 0.6), RespeakPick(candidate: 0, probability: 0.3)]
/// A client whose budget runs out only when a test advances `clock`, and whose
/// requests URLSession never times out, so no test races real time. Each test's
/// time limit stops a hang.
private func client(_ server: FakeJev, clock: TestClock = TestClock()) -> JevClient {
    JevClient(session: server.session, clock: clock, requestTimeout: 3_600)
}

@Test(.timeLimit(.minutes(1))) func jevAnswersWithEveryCandidateRankedAndItsProbability() async throws {
    let server = FakeJev { _ in (200, jevReply(["c1": 0.02, "c2": 0.97, "none": 0.01])) }
    let decision = await client(server).decide(question, access: server.access(), fallback: soundRanking)

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

@Test(.timeLimit(.minutes(1))) func aRequestThatTimesOutIsATimeoutNotAnError() async {
    // URLSession's own request limit is a timeout too, not an error.
    let server = FakeJev(failing: URLError(.timedOut))
    let decision = await client(server).decide(question, access: server.access(), fallback: soundRanking)
    #expect(decision.source == .fallback(.timeout))
}

@Test(.timeLimit(.minutes(1))) func pastTheBudgetTheFallbackDecides() async {
    let server = FakeJev()
    let clock = TestClock()
    let deciding = Task {
        await client(server, clock: clock).decide(question, access: server.access(), fallback: soundRanking)
    }
    for await _ in server.arrived { break }
    await clock.waitForSleep(endingAt: JevClient.budget)
    await clock.advance(by: JevClient.budget)
    let decision = await deciding.value
    #expect(decision.source == .fallback(.timeout))
    #expect(decision.answer == soundRanking)
}

@Test(.timeLimit(.minutes(1))) func privateModeDecidesLocallyWithNoRequest() async {
    let server = FakeJev { _ in (200, jevReply(["c1": 1])) }
    var privateMode = Preferences.defaults
    privateMode.privacy = .private
    let jev = client(server)

    jev.prewarm(server.access(privateMode))
    let decision = await jev.decide(question, access: server.access(privateMode), fallback: soundRanking)
    #expect(decision.source == .fallback(.privateMode))
    #expect(decision.answer == soundRanking)
    #expect(server.requests.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func privateModeTurnedOnMidCallDropsTheAnswerAtOnce() async {
    let server = FakeJev()
    let access = server.access()
    let deciding = Task {
        await client(server).decide(question, access: access, fallback: soundRanking)
    }
    for await _ in server.arrived { break }
    access?.revoke(.privateModeOn)
    #expect(await deciding.value.source == .fallback(.privateMode))
}

@Test(.timeLimit(.minutes(1))) func aCallerThatGaveUpStillGetsTheFallbackWithoutWaiting() async {
    let server = FakeJev()
    let deciding = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await client(server).decide(question, access: server.access(), fallback: soundRanking)
    }
    let decision = await deciding.value
    #expect(decision.answer == soundRanking)
    #expect(decision.source == .fallback(.cancelled))
    #expect(server.requests.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func aCallerThatGivesUpMidCallIsToldSoNotTimedOut() async {
    let server = FakeJev()  // never answers
    let deciding = Task { await client(server).decide(question, access: server.access(), fallback: soundRanking) }
    for await _ in server.arrived { break }
    deciding.cancel()
    #expect(await deciding.value.source == .fallback(.cancelled))
}

/// Key reads that wait until the test answers, as the first Keychain read can
/// wait on a prompt nobody has seen. Past `giveUp` every read is answered, so
/// a decide stuck on one fails its test instead of hanging the whole run.
private final class SlowKeychain: Sendable {
    private let answered = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let entries: AsyncStream<Void>.Continuation
    private let stuck = Mutex(false)
    let reading: AsyncStream<Void>
    /// The guard had to answer: something waited on a read that should not hold it.
    var gaveUp: Bool { stuck.withLock { $0 } }
    init(readers: Int = 1, giveUp seconds: Double = 30) {
        (reading, entries) = AsyncStream<Void>.makeStream()
        Thread.detachNewThread { [self] in
            guard finished.wait(timeout: .now() + seconds) == .timedOut else { return }  // timing-ok: a hang guard only
            stuck.withLock { $0 = true }
            (0..<readers).forEach { _ in answered.signal() }
        }
    }
    func read(_ key: String) -> String {
        entries.yield()
        answered.wait()  // timing-ok: a synchronous Keychain read, released by the test's answer(), never by time
        return key
    }
    func answer(_ readers: Int = 1) {
        finished.signal()
        (0..<readers).forEach { _ in answered.signal() }
    }
}

@Test(.timeLimit(.minutes(1))) func aKeyReadThatWaitsIsInsideTheBudget() async {
    let server = FakeJev { _ in (200, jevReply(["c1": 1])) }
    let keychain = SlowKeychain()
    let key = server.key
    let access = CloudAccess.granted(by: .defaults, for: .app(.unknown)) { $0 == .jev ? keychain.read(key) : nil }
    let clock = TestClock()
    let deciding = Task { await client(server, clock: clock).decide(question, access: access, fallback: soundRanking) }

    for await _ in keychain.reading { break }
    // The budget is already running while the key read waits.
    await clock.waitForSleep(endingAt: JevClient.budget)
    await clock.advance(by: JevClient.budget)
    let decision = await deciding.value
    #expect(!keychain.gaveUp)
    keychain.answer()
    #expect(decision.source == .fallback(.timeout))
    #expect(decision.answer == soundRanking)
}

@Test(.timeLimit(.minutes(1))) func aSecretInTheWordsSendsNothing() async throws {
    let server = FakeJev { _ in (200, jevReply(["c1": 1])) }
    let access = server.access()
    let secret = "ghp_" + "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xY2zA4"
    let leaky = try #require(JevQuestion.respeakTarget(
        spoken: "Supabase", spokenPhonetic: "SPBS", recent: "use \(secret) here",
        candidates: [RespeakCandidate(words: 2..<3, phonetic: "HR")]))
    let decision = await client(server).decide(leaky, access: access, fallback: [])
    #expect(decision.source == .fallback(.secretFound))
    #expect(access?.revoked == .secretFound)
    #expect(server.requests.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func noKeyOrABadReplyFallsBack() async {
    let noKey = await JevClient(clock: TestClock())
        .decide(question, access: CloudAccess.granted(by: .defaults, for: .app(.unknown)) { _ in nil }, fallback: soundRanking)
    #expect(noKey.source == .fallback(.noKey))

    for reply in [(500, jevReply(["c1": 1])), (200, Data("not json".utf8)), (200, jevReply(["unknown": 1]))] {
        let server = FakeJev { _ in reply }
        let decision = await client(server).decide(question, access: server.access(), fallback: soundRanking)
        #expect(decision.source == .fallback(.error))
        #expect(decision.answer == soundRanking)
    }
}

@Test func prewarmHasStartedItsRequestWhenItReturns() async {
    let server = FakeJev()
    let session = server.session
    JevClient(session: session, clock: TestClock(), requestTimeout: 3_600).prewarm(server.access())
    // On the session or already at the server: never still waiting to be started.
    let started = !(await session.allTasks).isEmpty || !server.requests.isEmpty
    #expect(started)
}

@Test(.timeLimit(.minutes(1))) func keyReadsWaitingOnPromptsCannotStopTheBudget() async {
    // More stuck reads than the cooperative pool has threads: the budget still runs out.
    let readers = ProcessInfo.processInfo.activeProcessorCount + 2
    let server = FakeJev { _ in (200, jevReply(["c1": 1])) }
    let keychain = SlowKeychain(readers: readers)
    let key = server.key
    let access = CloudAccess.granted(by: .defaults, for: .app(.unknown)) { $0 == .jev ? keychain.read(key) : nil }
    let clock = TestClock()
    let jev = client(server, clock: clock)
    let deciding = (0..<readers).map { _ in
        Task { await jev.decide(question, access: access, fallback: soundRanking) }
    }
    await clock.waitForSleepers(readers)
    await clock.advance(by: JevClient.budget)
    for decision in deciding { #expect(await decision.value.source == .fallback(.timeout)) }
    #expect(!keychain.gaveUp)
    keychain.answer(readers)
}

@Test(.timeLimit(.minutes(1))) func prewarmOpensTheConnectionWithoutTextOrKey() async throws {
    let server = FakeJev()
    client(server).prewarm(server.access())
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

@Test(.timeLimit(.minutes(1))) func tiedAnswersKeepTheCandidateOrder() async {
    let server = FakeJev { _ in (200, jevReply(["none": 0.4, "c2": 0.3, "c1": 0.3])) }
    let decision = await client(server).decide(question, access: server.access(), fallback: soundRanking)
    #expect(decision.answer.map(\.candidate) == [nil, 0, 1])
}

@Test(.timeLimit(.minutes(1))) func requestBodiesHoldOnlyTheWordsAroundEachCandidate() async throws {
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
    let server = FakeJev { _ in (200, jevReply(["c1": 1])) }
    let question = try #require(JevQuestion.respeakTarget(
        spoken: "word99", spokenPhonetic: "X", recent: words.joined(separator: " "), candidates: candidates))
    _ = await client(server).decide(question, access: server.access(), fallback: [])

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
