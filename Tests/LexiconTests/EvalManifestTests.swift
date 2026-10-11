import Foundation
import Testing
@testable import LexiconEval
import LexiconCore
import LexiconDomain

// `lexicon-eval --manifest` (#49): the real headless Conductor over a NeMo-style
// manifest, one run line per entry for the scorer. A scripted engine stands in
// for the speech model. No mic, keys or network. `--transcribe` (draft gold) runs
// the same over a manifest with no text.

private let gold = [
    (id: "a", text: "Um, so deploy the Supabase edge function today.", split: "everyday"),
    (id: "b", text: "Open App.tsx in the worktree.", split: "held-back"),
    (id: "c", text: "Run kubectl against the staging cluster.", split: "everyday"),
]

private func writeManifest(_ entries: [(id: String, text: String, split: String)], audio: String,
                           in dir: URL, withText: Bool = true) throws -> URL {
    let lines = try entries.map { entry in
        var object: [String: Any] = [
            "id": entry.id, "audio_filepath": audio, "duration": 0.5, "session": "s-\(entry.id)",
            "terms": [String](), "speech_end": 0.5, "context": "com.anthropic.claudefordesktop", "split": entry.split,
        ]
        if withText { object["text"] = entry.text }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    let url = dir.appending(path: "manifest.jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func fixtureManifest(withText: Bool = true) throws -> URL {
    let dir = try scratchDirectory()
    _ = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: dir)
    let wav = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path()).first)
    return try writeManifest(gold, audio: wav, in: dir, withText: withText)
}

@Test func eachEntryOfTheSplitRunsThroughThePipelineInOrder() async throws {
    let manifest = try fixtureManifest()

    let lines = try await runManifest(manifest, split: "everyday", pace: .asFastAsPossible) {
        ScriptedTranscriber(text: $0.text ?? "")
    }

    #expect(lines.map(\.id) == ["a", "c"])
    #expect(lines.map(\.status) == ["inserted", "inserted"])
    #expect(lines.map(\.speechText) == [gold[0].text, gold[2].text])
    // What was typed: the rules-only Cleanup of what the engine heard.
    #expect(lines.map(\.insertedText) == ["Deploy the Supabase edge function today.", gold[2].text])
    #expect(lines.allSatisfy { $0.lagMS != nil && !$0.lost })
    #expect(lines.allSatisfy { $0.engine == SpeechModel.local(.parakeetUnified).id && $0.cleanup != nil })
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

@Test func aManifestWithNoTextRunsEveryEntryInPrivateModeAtFastPace() async throws {
    let manifest = try fixtureManifest(withText: false)
    var preferences = Preferences.defaults
    preferences.privacy = .private
    let engine = ScriptedTranscriber(text: gold[0].text)

    let lines = try await runManifest(manifest, split: nil, pace: .asFastAsPossible, preferences: preferences) { _ in engine }

    #expect(lines.map(\.id) == ["a", "b", "c"])
    #expect(lines.map(\.speechText) == Array(repeating: gold[0].text, count: 3))
    #expect(lines.allSatisfy { $0.status == "inserted" })
    #expect(await engine.heard.count == 3)
}

@Test func transcribeWritesOneLinePerEntryWithNoLag() async throws {
    let manifest = try fixtureManifest(withText: false)
    let out = try scratchDirectory().appending(path: "run.jsonl")
    let engine = ScriptedTranscriber(text: gold[0].text)

    try await transcribeManifest(manifest, to: out) { _ in engine }

    let objects = try String(contentsOf: out, encoding: .utf8).split(whereSeparator: \.isNewline).map { line in
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    #expect(objects.map { $0["id"] as? String } == ["a", "b", "c"])
    #expect(objects.allSatisfy { ($0["speech_text"] as? String) == gold[0].text })
    #expect(objects.allSatisfy { $0["lag_ms"] == nil })
}

@Test func transcribeNeverOverwritesAnExistingFile() async throws {
    let manifest = try fixtureManifest(withText: false)
    let out = try scratchDirectory().appending(path: "run.jsonl")
    try Data("existing\n".utf8).write(to: out)
    let engine = ScriptedTranscriber(text: gold[0].text)

    await #expect(throws: EvalError.self) {
        try await transcribeManifest(manifest, to: out) { _ in engine }
    }
    #expect(await engine.heard.isEmpty)  // refused before the first entry runs
    #expect(try String(contentsOf: out, encoding: .utf8) == "existing\n")
}

@Test func pathsWithASpaceWorkLikeTheTestSetFolder() async throws {
    // The private Test set lives under "Application Support".
    let dir = try scratchDirectory().appending(path: "Application Support")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: dir)
    let wav = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).first)
    let manifest = try writeManifest(gold, audio: dir.appending(path: wav).path(percentEncoded: false), in: dir,
                                     withText: false)
    let out = dir.appending(path: "run one.jsonl")
    let engine = ScriptedTranscriber(text: gold[0].text)

    try await transcribeManifest(manifest, to: out) { _ in engine }
    #expect(await engine.heard.count == 3)
    await #expect(throws: EvalError.self) {
        try await transcribeManifest(manifest, to: out) { _ in engine }
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

@Test func aRunFileGoesInsideAGitWorkTreeOnlyForAManifestInsideThisRepo() throws {
    // main/.git holds main/worktrees/repo, like ~/code/lexicon and its worktrees.
    let root = try scratchDirectory()
    let main = root.appending(path: "main")
    let repo = main.appending(path: "worktrees/repo")
    try FileManager.default.createDirectory(at: main.appending(path: ".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo.appending(path: "scorer"), withIntermediateDirectories: true)
    try Data().write(to: repo.appending(path: ".git"))  // a worktree's .git is a file
    let fixture = repo.appending(path: "scorer/manifest.jsonl")
    let privateSet = root.appending(path: "test-set/manifest.jsonl")

    #expect(mayWriteRun(to: repo.appending(path: "run.jsonl"), manifest: fixture, repo: repo))
    #expect(mayWriteRun(to: root.appending(path: "runs/run.jsonl"), manifest: privateSet, repo: repo))
    #expect(!mayWriteRun(to: repo.appending(path: "run.jsonl"), manifest: privateSet, repo: repo))
    #expect(!mayWriteRun(to: repo.appending(path: "scorer/../run.jsonl"), manifest: privateSet, repo: repo))
    #expect(!mayWriteRun(to: main.appending(path: "run.jsonl"), manifest: privateSet, repo: repo))
    #expect(!mayWriteRun(to: main.appending(path: "worktrees/other/run.jsonl"), manifest: privateSet, repo: repo))
}
