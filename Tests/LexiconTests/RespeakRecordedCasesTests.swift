import Foundation
import Testing
@testable import Jev
import Fixes
import LexiconDomain
import WordStore

// The right span wins on every synthesized case (RespeakCases.swift): by sound
// alone, as in Private mode, and through a fake Jev that knows the answer, so
// the right span must be among the few Jev is shown and come back as itself.

private func resolver(_ server: FakeJev) -> RespeakResolver {
    RespeakResolver(jev: JevClient(session: server.session, clock: TestClock(), requestTimeout: 3_600))
}

/// The options Jev was shown, by option name ("c1"...), with their text. Jev
/// is shown whole words, so "tail wind," keeps its comma; the span Lexicon
/// replaces doesn't.
private func shown(_ body: Data) -> [String: String] {
    struct Request: Decodable {
        struct State: Decodable { let candidates: [String: [String: String]] }
        let state: State
    }
    let request = try? JSONDecoder().decode(Request.self, from: body)
    let edges = CharacterSet(charactersIn: ".,;:!?\"'()[]{}<>“”‘’…")
    return request?.state.candidates.compactMapValues { $0["text"]?.trimmingCharacters(in: edges) } ?? [:]
}

@Test(.timeLimit(.minutes(1)), arguments: respeakCases)
func bySoundAloneTheRightSpanWins(_ example: RespeakCase) async {
    let server = FakeJev()
    let resolution = await resolver(server).resolve(example.spoken, recent: example.recent, access: nil)

    #expect(server.requests.isEmpty)
    guard let (text, start) = example.expected else {
        #expect(resolution == .noMatch)
        return
    }
    guard case .pick(let span) = resolution else {
        Issue.record("expected a pick of \(text), got \(resolution)")
        return
    }
    #expect(span.text == text)
    #expect(span.words.lowerBound == start)
}

@Test(.timeLimit(.minutes(1)), arguments: respeakCases.filter { $0.expected != nil })
func jevIsShownTheRightSpanAndItsPickLands(_ example: RespeakCase) async throws {
    let (text, start) = try #require(example.expected)
    let server = FakeJev { body in
        let options = shown(body)
        // A repeated span's options share a text. Options are numbered best
        // first by sound, and of two equal spans the later one ranks first.
        let right = options.filter { $0.value == text }.keys.sorted().first
        return (200, jevReply(right.map { [$0: 0.95, "none": 0.05] } ?? ["none": 1]))
    }
    let resolution = await resolver(server).resolve(example.spoken, recent: example.recent, access: server.access())

    #expect(server.requests.count == 1)
    guard case .pick(let span) = resolution else {
        Issue.record("expected a pick of \(text), got \(resolution)")
        return
    }
    #expect(span.text == text)
    #expect(span.words.lowerBound == start)
}
