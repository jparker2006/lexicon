import Foundation
import Testing
@testable import Jev
import Fixes
import LexiconDomain
import WordStore

// Re-speak's sound side (#82). Private mode picks from the sound ranking alone,
// with no request at all; the candidate finder ranks the recent text by sound.
// Same shape as JevClientTests: a fake Jev server, a client on its session with
// a test clock, and no real time.

private let recent = "I pushed the schema to super base last night."

/// A resolver on the fake server's session. If Jev were asked, its reply would
/// pick the second candidate, not the sound ranking's best, so a resolver that
/// asked Jev in Private mode would return a different span.
private func resolver(_ server: FakeJev) -> RespeakResolver {
    RespeakResolver(jev: JevClient(session: server.session, clock: TestClock(), requestTimeout: 3_600))
}

@Test(.timeLimit(.minutes(1))) func privateModeReturnsAPickWithNoNetworkCall() async {
    let server = FakeJev { _ in (200, jevReply(["c2": 0.99, "none": 0.01])) }
    var privateMode = Preferences.defaults
    privateMode.privacy = .private
    let access = CloudAccess.granted(by: privateMode, for: .app(.unknown)) { $0 == .jev ? server.key : nil }
    #expect(access == nil)

    let resolution = await resolver(server).resolve("Supabase", recent: recent, access: access)
    guard case .pick(let candidate) = resolution else {
        Issue.record("expected .pick in Private mode, got \(resolution)")
        return
    }
    #expect(candidate.text == "super base")
    #expect(server.requests.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func privateModeWithNothingCloseChangesNothing() async {
    let server = FakeJev { _ in (200, jevReply(["c1": 0.99, "none": 0.01])) }

    let resolution = await resolver(server).resolve("Kubernetes", recent: "Lunch is at noon, see you then.",
                                                    access: nil)
    #expect(resolution == .noMatch)
    #expect(server.requests.isEmpty)
}

@Test func theSpanThatSoundsLikeTheSpokenWordIsFirstWithItsRangeInTheText() throws {
    let best = try #require(CandidateFinder.candidates(for: "Supabase", in: recent).first)
    #expect(best.text == "super base")
    #expect(best.words == 5..<7)
    let utf16 = NSRange(location: best.utf16.lowerBound, length: best.utf16.count)
    #expect((recent as NSString).substring(with: utf16) == "super base")
}

@Test func punctuationAtTheEdgeOfASpanIsNotPartOfIt() throws {
    let candidates = CandidateFinder.candidates(for: "Vercel", in: "we use verse el.")
    let best = try #require(candidates.first)
    #expect(best.text == "verse el")
    #expect(candidates.allSatisfy { !$0.text.contains(".") })
}

@Test func everyCandidateIsOneToThreeWordsAndNoneIsEmpty() {
    let candidates = CandidateFinder.candidates(for: "Supabase", in: recent)
    #expect(!candidates.isEmpty)
    #expect(candidates.allSatisfy { (1...3).contains($0.words.count) && !$0.text.isEmpty })
}

@Test func recentTextWithNoWordsHasNoCandidates() {
    #expect(CandidateFinder.candidates(for: "Supabase", in: "").isEmpty)
}

@Test func aTieGoesToTheSpanNearerTheEnd() throws {
    let best = try #require(CandidateFinder.candidates(for: "SQL", in: "sequel then more sequel").first)
    #expect(best.words == 3..<4)
}

@Test func thePhoneticCodeIsTheSoundNotTheSpelling() {
    #expect(!Phonetic.code("Supabase").isEmpty)
    #expect(Phonetic.code("super base") == Phonetic.code("SUPER-BASE"))
}
