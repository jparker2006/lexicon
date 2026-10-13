import Foundation
import Testing
@testable import Jev
import Fixes

// Re-speak's answer from Jev (#82): a sure answer picks its span, an unsure one
// offers the choices in Jev's order, "none" changes nothing, and a Jev that
// fails leaves the sound ranking to decide. Same shape as JevClientTests: a fake
// Jev server, the resolver on its session with a test clock, and no real time.

private let recentText = "okay now wire the auth callback into super base and then redeploy to vercel"
private let spokenWord = "Supabase"
private let superBase = "super base"

private func jevResolver(_ server: FakeJev) -> RespeakResolver {
    RespeakResolver(jev: JevClient(session: server.session, clock: TestClock(), requestTimeout: 3_600))
}

/// The texts Jev was sent, keyed by the "cN" option the request gave each one.
private func sentTexts(_ body: Data) -> [String: String] {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let state = json["state"] as? [String: Any],
          let candidates = state["candidates"] as? [String: [String: Any]] else { return [:] }
    return candidates.compactMapValues { $0["text"] as? String }
}

/// Jev's reply, with each probability given by the text of the candidate it
/// belongs to. The "cN" key is read from the request, never assumed. A request
/// that names none of the texts gets a 500, which is a Jev that failed.
private func jevAnswer(_ body: Data, _ byText: ([String: String]) -> [String: Double]) -> (status: Int, body: Data)? {
    let sent = sentTexts(body)
    let answer = byText(sent)
    var byKey: [String: Double] = [:]
    for (key, text) in sent {
        if let probability = answer[text] { byKey[key] = probability }
    }
    if let none = answer["none"] { byKey["none"] = none }
    guard !byKey.isEmpty else { return (500, Data()) }
    return (200, jevReply(byKey))
}

/// The texts Jev was sent other than "super base", highest "cN" key first. The
/// lower probabilities go to these in this order, so Jev's order is not the
/// sound order (c1 is the best sound match).
private func otherTexts(_ sent: [String: String]) -> [String] {
    var texts: [String] = []
    for text in sent.sorted(by: { $0.key > $1.key }).map({ $0.value })
    where text != superBase && !texts.contains(text) {
        texts.append(text)
    }
    return texts
}

@Test(.timeLimit(.minutes(1))) func jevSureOfASpanPicksIt() async throws {
    let server = FakeJev { body in jevAnswer(body) { _ in [superBase: 0.9] } }
    let resolution = await jevResolver(server).resolve(spokenWord, recent: recentText, access: server.access())

    guard case .pick(let span) = resolution else {
        Issue.record("expected .pick, got \(resolution)")
        return
    }
    #expect(span.text == superBase)
    #expect(span.words == 7..<9)
    #expect(server.requests.count == 1)
}

@Test(.timeLimit(.minutes(1))) func jevSureOfASpanPicksThatSpanNotTheSoundBest() async throws {
    // Jev is sure of the highest-keyed other span, never the sound ranking's first,
    // so the pick must follow Jev's answer and not the sound ranking.
    let server = FakeJev { body in
        jevAnswer(body) { sent in
            guard let other = otherTexts(sent).first else { return [:] }
            return [other: 0.9]
        }
    }
    let resolution = await jevResolver(server).resolve(spokenWord, recent: recentText, access: server.access())

    guard case .pick(let span) = resolution else {
        Issue.record("expected .pick, got \(resolution)")
        return
    }
    let request = try #require(server.requests.first)
    let expected = try #require(otherTexts(sentTexts(request.body)).first)
    #expect(span.text == expected)
}

@Test(.timeLimit(.minutes(1))) func underTheCutoffJakeGetsChoicesInJevsOrder() async throws {
    let server = FakeJev { body in
        jevAnswer(body) { sent in
            var answer: [String: Double] = [superBase: 0.5, "none": 0.05]
            for (text, probability) in zip(otherTexts(sent), [0.3, 0.15]) { answer[text] = probability }
            return answer
        }
    }
    let resolution = await jevResolver(server).resolve(spokenWord, recent: recentText, access: server.access())

    guard case .choices(let spans) = resolution else {
        Issue.record("expected .choices, got \(resolution)")
        return
    }
    let request = try #require(server.requests.first)
    let others = otherTexts(sentTexts(request.body))
    #expect(spans.map(\.text) == [superBase] + Array(others.prefix(2)))
    #expect(!spans.map(\.text).contains("none"))
}

@Test(.timeLimit(.minutes(1))) func twoOptionsUnderTheCutoffAreChoicesAndNoneIsNeverOne() async throws {
    // Only two candidates get probability; "none" takes the rest and is not a choice.
    let server = FakeJev { body in
        jevAnswer(body) { sent in
            var answer: [String: Double] = [superBase: 0.5, "none": 0.2]
            if let other = otherTexts(sent).first { answer[other] = 0.3 }
            return answer
        }
    }
    let resolution = await jevResolver(server).resolve(spokenWord, recent: recentText, access: server.access())

    guard case .choices(let spans) = resolution else {
        Issue.record("expected .choices, got \(resolution)")
        return
    }
    let request = try #require(server.requests.first)
    let others = otherTexts(sentTexts(request.body))
    #expect(spans.map(\.text) == [superBase] + Array(others.prefix(1)))
    #expect(spans.count == 2)
}

@Test(.timeLimit(.minutes(1))) func exactlyAtTheCutoffIsSure() async throws {
    let server = FakeJev { body in jevAnswer(body) { _ in [superBase: RespeakResolver.sureAt] } }
    let resolution = await jevResolver(server).resolve(spokenWord, recent: recentText, access: server.access())

    guard case .pick(let span) = resolution else {
        Issue.record("expected .pick at the cutoff, got \(resolution)")
        return
    }
    #expect(span.text == superBase)
}

@Test(.timeLimit(.minutes(1))) func jevSaysNoneChangesNothing() async throws {
    // The no-match result has to come from Jev's "none" answer, so each case also
    // checks that Jev was asked: a resolver that never asks would look the same.
    let sureNone = FakeJev { body in jevAnswer(body) { _ in ["none": 0.9] } }
    let resolution = await jevResolver(sureNone).resolve(spokenWord, recent: recentText, access: sureNone.access())
    #expect(sureNone.requests.count == 1)
    #expect(resolution == RespeakResolution.noMatch)

    let topNone = FakeJev { body in jevAnswer(body) { _ in ["none": 0.5, superBase: 0.3] } }
    let topResolution = await jevResolver(topNone).resolve(spokenWord, recent: recentText, access: topNone.access())
    #expect(topNone.requests.count == 1)
    #expect(topResolution == RespeakResolution.noMatch)
}

@Test(.timeLimit(.minutes(1))) func aJevFailureFallsBackToSound() async throws {
    let server = FakeJev { _ in (500, Data()) }
    let resolution = await jevResolver(server).resolve(spokenWord, recent: recentText, access: server.access())

    guard case .pick(let span) = resolution else {
        Issue.record("expected the sound ranking's pick after Jev failed, got \(resolution)")
        return
    }
    #expect(span.text == superBase)
    #expect(span.words == 7..<9)
    #expect(server.requests.count == 1)
}
