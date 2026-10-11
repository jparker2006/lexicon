import Foundation
import Testing
import Cleanup
import LexiconDomain
import WordStore
import LexiconCore

// The Lexicon store: the Terms and Rules a user adds and removes, what survives a
// reopen, and what a Dictation sees of them. Terms fold spoken variants, Rules
// replace whole words, and both run in TextPass in every mode. Made-up words only,
// in throwaway folders.

/// A Lexicon in a throwaway folder, holding the given Terms and Rules (heard, written).
private func lexicon(terms: [String], rules: [(String, String)]) async throws -> Lexicon {
    let store = try Lexicon(paths: .temporary())
    for text in terms { try await store.add(Term(text: text)) }
    for (heard, written) in rules { try await store.add(Rule(heard: heard, written: written)) }
    return store
}

/// What a Dictation started now would type for `text`, with rules only.
private func apply(_ text: String, _ store: Lexicon) async -> String {
    await store.forDictation(in: .unknown).rules.apply(to: text)
}

@Test func variantsFoldToTheTerm() async throws {
    let store = try await lexicon(terms: ["gstack", "ELI5", "CLAUDE.md"], rules: [])
    let cases = [
        ("Install G stack today", "Install gstack today"),
        ("Install g-stack today", "Install gstack today"),
        ("Install GStack today", "Install gstack today"),
        ("Explain it ELI five.", "Explain it ELI5."),
        ("Explain it eli 5", "Explain it ELI5"),
        ("Explain it E L I five", "Explain it ELI5"),
        ("Read (G stack), then claude.md.", "Read (gstack), then CLAUDE.md."),
        ("gstack and ELI5 stay", "gstack and ELI5 stay"),
    ]
    for (raw, gold) in cases {
        #expect(await apply(raw, store) == gold, "\(raw)")
    }
}

@Test func plainEnglishNeverFoldsIntoATerm() async throws {
    let store = try await lexicon(terms: ["WorkTree", "Linear", "AppKit", "Notion"], rules: [])
    for text in ["Make a work tree for it", "Use a linear search", "Ship the app kit today",
                 "I have a notion it works", "Make two work trees"] {
        #expect(await apply(text, store) == text, "\(text)")
    }
    #expect(await apply("Open the worktree", store) == "Open the WorkTree")
}

@Test func aRuleAppliesExactly() async throws {
    let store = try await lexicon(terms: [], rules: [("codecs", "Codex"), ("super base", "Supabase"),
                                                     ("slash review", "/review")])
    #expect(await apply("Ask codecs to review it.", store) == "Ask Codex to review it.")
    #expect(await apply("Ask CODECS, then stop", store) == "Ask Codex, then stop")
    #expect(await apply("Wire auth into super base.", store) == "Wire auth into Supabase.")
    #expect(await apply("Wire auth into super-base", store) == "Wire auth into Supabase")
    #expect(await apply("Run slash review now", store) == "Run /review now")
    // Whole words only: "codecsx" is a different word, and so is "super, base".
    #expect(await apply("The codecsx file and super, base stay", store) == "The codecsx file and super, base stay")
}

@Test func rulesNeverRescanTheirOwnOutput() async throws {
    // "bar" written by the first Rule is final: the second Rule does not rewrite it.
    let chain = try await lexicon(terms: [], rules: [("foo", "bar"), ("bar", "baz")])
    #expect(await apply("foo bar", chain) == "bar baz")
    // The longer heard wins, so "super base" is not read as "super" followed by "base".
    let nested = try await lexicon(terms: [], rules: [("super", "Super!"), ("super base", "Supabase")])
    #expect(await apply("super base", nested) == "Supabase")
}

@Test func addingTwiceKeepsOneEntryAndRemoveStopsIt() async throws {
    let store = try Lexicon(paths: .temporary())
    try await store.add(Term(text: "gstack"))
    try await store.add(Term(text: "GStack"))
    #expect(await store.terms.count == 1)
    try await store.add(Rule(heard: "codecs", written: "Codex"))
    try await store.add(Rule(heard: "Codecs", written: "CodeX"))
    #expect(await store.rules.count == 1)
    #expect(await apply("codecs", store) == "CodeX")

    try await store.remove(Rule(heard: "codecs", written: "Codex"))
    try await store.remove(Term(text: "gstack"))
    #expect(await store.terms.isEmpty)
    #expect(await store.rules.isEmpty)
    #expect(await apply("codecs G stack", store) == "codecs G stack")
}

@Test func theLexiconSurvivesAReopen() async throws {
    let paths = AppPaths.temporary()
    let first = try Lexicon(paths: paths)
    try await first.add(Term(text: "gstack"))
    try await first.add(Rule(heard: "codecs", written: "Codex", source: .learned))

    let second = try Lexicon(paths: paths)
    #expect(await second.terms.map(\.text) == ["gstack"])
    #expect(await second.rules == [Rule(heard: "codecs", written: "Codex", source: .learned)])
    #expect(await apply("codecs G stack", second) == "Codex gstack")
}

@Test func aDictationKeepsTheWordsItStartedWith() async throws {
    let store = try Lexicon(paths: .temporary())
    let words = await store.forDictation(in: .unknown)
    try await store.add(Rule(heard: "codecs", written: "Codex"))
    // The snapshot is taken at fn-down: a Rule added mid-Dictation changes nothing in flight.
    #expect(words.rules.apply(to: "ask codecs") == "ask codecs")
    #expect(await apply("ask codecs", store) == "ask Codex")
}

@Test func aTermKeepsItsCaseAfterAFillerIsDropped() async throws {
    let store = try await lexicon(terms: ["gstack"], rules: [])
    let rules = await store.forDictation(in: .unknown).rules
    #expect(TextPass.run("Um, gstack is ready.", rules: rules) == "gstack is ready.")
    #expect(TextPass.run("Um, G stack is ready.", rules: rules) == "gstack is ready.")
}

@Test(arguments: [true, false])
func rulesAndFoldingRunInEveryMode(privateMode: Bool) async throws {
    var prefs = Preferences.defaults
    if privateMode { prefs.privacy = .private } else { prefs.aiCleanup = false }
    let paths = AppPaths.temporary()
    let seeded = try Lexicon(paths: paths)
    try await seeded.add(Term(text: "gstack"))
    try await seeded.add(Rule(heard: "codecs", written: "Codex"))

    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
    let system = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: prefs,
                                         local: ScriptedTranscriber(text: "Um, ask codecs to run G stack."))
    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)

    #expect(result.status == .inserted)
    #expect(result.versions?.cleaned == "Ask Codex to run gstack.")
}

// The target is under 1 ms for 200 Terms and Rules on a 100-word Dictation. It is
// measured on demand with LEXICON_BENCH=1 and never runs in CI: tests never depend
// on machine speed.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LEXICON_BENCH"] != nil))
func applyingTwoHundredTermsAndRulesToAHundredWordsTakesUnderAMillisecond() async throws {
    let store = try await lexicon(terms: (0..<100).map { "Zq\($0)Kit" },
                                  rules: (0..<100).map { ("zork \($0)", "Zork\($0)") })
    let rules = await store.forDictation(in: .unknown).rules
    let text = Array(repeating: "please ship zq 7 kit and zork 12 to the", count: 10).joined(separator: " ")
    #expect(text.split(separator: " ").count == 100)

    _ = rules.apply(to: text)  // warm up
    let clock = ContinuousClock()
    var times: [Duration] = []
    for _ in 0..<50 {
        times.append(clock.measure { _ = rules.apply(to: text) })
    }
    let fastest = try #require(times.min())
    let median = times.sorted()[times.count / 2]
    print("fastest \(fastest), median \(median)")
    #expect(fastest < .milliseconds(1))
}
