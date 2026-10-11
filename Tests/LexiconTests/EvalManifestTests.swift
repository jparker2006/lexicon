import Foundation
import Testing
@testable import LexiconEval
import LexiconCore
import LexiconDomain

// `lexicon-eval --manifest` (#49): the real headless Conductor over a NeMo-style
// manifest, one run line per entry for the scorer. A scripted engine stands in
// for the speech model. No mic, keys or network.

private let gold = [
    (id: "a", text: "Um, so deploy the Supabase edge function today.", split: "everyday"),
    (id: "b", text: "Open App.tsx in the worktree.", split: "held-back"),
    (id: "c", text: "Run kubectl against the staging cluster.", split: "everyday"),
]

private func writeManifest(_ entries: [(id: String, text: String, split: String)], audio: String,
                           in dir: URL) throws -> URL {
    let lines = try entries.map { entry in
        let object: [String: Any] = [
            "id": entry.id, "audio_filepath": audio, "duration": 0.5, "text": entry.text, "session": "s-\(entry.id)",
            "terms": [String](), "speech_end": 0.5, "context": "com.anthropic.claudefordesktop", "split": entry.split,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    let url = dir.appending(path: "manifest.jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func fixtureManifest() throws -> URL {
    let dir = try scratchDirectory()
    _ = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: dir)
    let wav = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path()).first)
    return try writeManifest(gold, audio: wav, in: dir)
}

@Test func eachEntryOfTheSplitRunsThroughThePipelineInOrder() async throws {
    let manifest = try fixtureManifest()

    let lines = try await runManifest(manifest, split: "everyday", pace: .asFastAsPossible) {
        ScriptedTranscriber(text: $0.text)
    }

    #expect(lines.map(\.id) == ["a", "c"])
    #expect(lines.map(\.status) == ["inserted", "inserted"])
    #expect(lines.map(\.speechText) == [gold[0].text, gold[2].text])
    // What was typed: the rules-only Cleanup of what the engine heard.
    #expect(lines.map(\.insertedText) == ["Deploy the Supabase edge function today.", gold[2].text])
    #expect(lines.allSatisfy { $0.lagMS != nil && !$0.lost })
    #expect(lines.allSatisfy { $0.engine == "local:parakeet-unified-0.6b-en" && $0.cleanup == "rules-only:off" })
}

@Test func withNoEngineEveryEntryWaitsAndScoresAsNoText() async throws {
    let manifest = try fixtureManifest()

    let lines = try await runManifest(manifest, split: nil, pace: .asFastAsPossible) { _ in nil }

    #expect(lines.map(\.id) == ["a", "b", "c"])
    #expect(lines.allSatisfy { $0.status == "waiting" && $0.speechText.isEmpty && $0.insertedText.isEmpty })
    #expect(lines.allSatisfy { $0.lagMS == nil && $0.engine == nil && !$0.lost })  // audio kept for the retry
}

@Test func aManifestWithMissingAudioStopsBeforeAnyEntryRuns() async throws {
    let dir = try scratchDirectory()
    let manifest = try writeManifest(gold, audio: "missing.wav", in: dir)
    let engine = ScriptedTranscriber(text: "never heard")

    await #expect(throws: EvalError.self) {
        try await runManifest(manifest, split: nil, pace: .asFastAsPossible) { _ in engine }
    }
    #expect(await engine.heard.isEmpty)
}

@Test func aSplitWithNoEntriesIsAnError() async throws {
    let manifest = try fixtureManifest()
    await #expect(throws: EvalError.self) {
        try await runManifest(manifest, split: "nope", pace: .asFastAsPossible) { _ in nil }
    }
}

@Test func runLinesUseTheScorersFieldNames() throws {
    let line = RunLine(id: "a", status: "inserted", speechText: "x", insertedText: "X.", lagMS: 12,
                       cleanup: "rules-only:off", engine: "local:parakeet-unified-0.6b-en", lost: false)
    let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(line)) as? [String: Any])
    #expect(Set(object.keys) == ["id", "status", "speech_text", "inserted_text", "lag_ms", "cleanup", "engine", "lost"])
}

@Test func aDictationIsLostOnlyWhenItsTextAndAudioAreBothGone() {
    #expect(!isLost(reported: .inserted, saved: (.inserted, .onDisk)))
    #expect(!isLost(reported: .waiting, saved: (.waiting, .onDisk)))
    #expect(!isLost(reported: nil, saved: nil))  // nothing was recorded, so nothing was lost
    #expect(isLost(reported: .inserted, saved: nil))  // no History row
    #expect(isLost(reported: .waiting, saved: (.waiting, .ramOnly)))  // the RAM clip is gone when the run ends
    #expect(isLost(reported: .failed, saved: (.failed, .deleted)))
}

@Test func aRunFileGoesInsideTheRepoOnlyForAManifestInsideIt() {
    let repo = URL(filePath: "/code/lexicon")
    let fixture = repo.appending(path: "scorer/fixtures/manifest.jsonl")
    let privateSet = URL(filePath: "/Users/j/Library/Application Support/Lexicon/test-set/manifest.jsonl")

    #expect(mayWriteRun(to: repo.appending(path: "run.jsonl"), manifest: fixture, repo: repo))
    #expect(mayWriteRun(to: URL(filePath: "/tmp/run.jsonl"), manifest: privateSet, repo: repo))
    #expect(!mayWriteRun(to: repo.appending(path: "run.jsonl"), manifest: privateSet, repo: repo))
    #expect(!mayWriteRun(to: repo.appending(path: "scorer/../out/run.jsonl"), manifest: privateSet, repo: repo))
    #expect(!mayWriteRun(to: URL(filePath: "/code/lexicon/"), manifest: privateSet, repo: repo))
    #expect(mayWriteRun(to: URL(filePath: "/code/lexicon-runs/run.jsonl"), manifest: privateSet, repo: repo))
}
