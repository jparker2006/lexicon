import Foundation
import Synchronization
import LexiconDomain
import LexiconCore
import LocalParakeet
import Transcription

// `lexicon-eval`: dev tool, never shipped. Runs the real Conductor headless, at
// the speed of speech, on one WAV or on every entry of a manifest.
//
//   swift run lexicon-eval <wav> [--scripted <text>]
//       {"status": "inserted", "text": "...", "lag_ms": 42}
//
//   swift run lexicon-eval --manifest <manifest.jsonl> [--split <name>]
//       [--baseline <run.jsonl>] [--out <run.jsonl>] [--scripted-gold]
//       the report from `scorer/score report` (see scorer/README.md)
//
//   swift run lexicon-eval --install-model <data folder>
//       downloads the local model into `<data folder>/models/`
//       (`scripts/install-model.sh` runs it until onboarding exists)
//
// `lag_ms` is end of audio to text typed (the recording destination's "paste").
// `--scripted` stands in a fake engine that hears <text>, and `--scripted-gold`
// one that hears each entry's gold text, to check the pipeline on a Mac with no
// model. Without them local Parakeet runs from Lexicon Dev's `models/` (a
// symlink to the daily copy's once that is installed); with no model there,
// every Dictation waits and scores as no text.
//
// A manifest run writes one run line per entry (`--out` keeps the file; it is
// what a later run's `--baseline` reads), then passes it to the scorer and exits
// with the scorer's code: 0, or 3 when a score got worse than the baseline.
// The quick run is `--split everyday`; the full run is `--split held-back`.
//
// Keys come from LEXICON_KEY_* environment variables (Secrets(.environment)).
// History and audio go to temporary folders deleted after each Dictation, never
// to an app's data folder.

/// This checkout: the scorer lives here, and only a manifest inside it is public
/// (`mayWriteRun`).
let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

struct Line: Encodable {
    let status: String
    let text: String?
    let lag_ms: Int?
}

func runEval(arguments: [String]) async -> Int32 {
    var options: [String: String] = [:]
    var scriptedGold = false
    var files: [String] = []
    var rest = arguments.dropFirst()
    while let argument = rest.popFirst() {
        switch argument {
        case "--scripted-gold": scriptedGold = true
        case "--scripted", "--manifest", "--split", "--baseline", "--out", "--install-model":
            guard let value = rest.popFirst(), options[argument] == nil else { return usage() }
            options[argument] = value
        default:
            guard !argument.hasPrefix("--") else { return usage() }
            files.append(argument)
        }
    }
    if let folder = options["--install-model"] {
        guard options.count == 1, files.isEmpty, !scriptedGold else { return usage() }
        return await installModel(into: URL(filePath: folder, directoryHint: .isDirectory))
    }
    if let manifest = options["--manifest"] {
        guard files.isEmpty, options["--scripted"] == nil else { return usage() }
        return await evalManifest(URL(filePath: manifest), split: options["--split"],
                                  baseline: options["--baseline"].map { URL(filePath: $0) },
                                  out: options["--out"].map { URL(filePath: $0) }, scriptedGold: scriptedGold)
    }
    guard files.count == 1, options.keys.allSatisfy({ $0 == "--scripted" }), !scriptedGold else { return usage() }
    return await evalFile(URL(filePath: files[0]), scripted: options["--scripted"])
}

func evalFile(_ wav: URL, scripted: String?) async -> Int32 {
    let paths = AppPaths.temporary()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let system: HeadlessSystem
    do {
        system = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                                         local: scripted.map(ScriptedTranscriber.init(text:)) ?? parakeet)
    } catch {
        return fail("\(error)")
    }
    let result = await system.conductor.dictate(file: wav, pace: .realtime)
    await system.history.flush()

    let line = Line(status: result.status?.rawValue ?? "nothing", text: result.versions?.cleaned,
                    lag_ms: result.lag.map { Int($0 / .milliseconds(1)) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: (try? encoder.encode(line)) ?? Data(), as: UTF8.self))
    return result.status == nil ? 1 : 0
}

func evalManifest(_ manifest: URL, split: String?, baseline: URL?, out: URL?, scriptedGold: Bool) async -> Int32 {
    if let out {
        guard mayWriteRun(to: out, manifest: manifest, repo: repo) else {
            return fail("--out is inside a git repo but the manifest is not public; Test set text never goes in a repo")
        }
        // Never over a manifest, a baseline or another run: they may be Jake's data.
        guard !FileManager.default.fileExists(atPath: out.path()) else { return fail("--out already exists") }
    }
    let lines: [RunLine]
    do {
        lines = try await runManifest(manifest, split: split, pace: .realtime) { entry in
            scriptedGold ? ScriptedTranscriber(text: entry.text) as any LocalTranscriber : parakeet
        } progress: { done, total in
            FileHandle.standardError.write(Data("lexicon-eval: \(done)/\(total)\r".utf8))
        }
    } catch {
        return fail("\(error)")
    }
    FileHandle.standardError.write(Data("\n".utf8))

    let runFile = out ?? FileManager.default.temporaryDirectory.appending(path: "lexicon-run-\(UUID().uuidString).jsonl")
    defer { if out == nil { try? FileManager.default.removeItem(at: runFile) } }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        let body = try lines.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }.joined()
        try body.write(to: runFile, atomically: true, encoding: .utf8)
    } catch {
        return fail("cannot write the run file: \(error.localizedDescription)")
    }

    var arguments = [repo.appending(path: "scorer/score").path(), "report", "--gold", manifest.path(),
                     "--run", runFile.path()]
    if let split { arguments += ["--split", split] }
    if let baseline { arguments += ["--baseline", baseline.path()] }
    let scorer = Process()
    scorer.executableURL = URL(filePath: "/bin/sh")
    scorer.arguments = arguments
    do { try scorer.run() } catch { return fail("cannot start the scorer: \(error.localizedDescription)") }
    scorer.waitUntilExit()
    return scorer.terminationStatus
}

/// Local Parakeet, loaded once and kept for the whole run. Every Dictation here
/// builds its own SpeechEngine, and a finished one's idle timer would otherwise
/// unload the shared model under a later Dictation and add a reload to its lag.
struct PinnedModel: LocalTranscriber {
    let parakeet: ParakeetTranscriber
    var model: LocalModel { parakeet.model }
    var isResident: Bool { get async { await parakeet.isResident } }
    func load() async throws { try await parakeet.load() }
    func unload() async {}
    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) async throws -> String {
        try await parakeet.transcribe(clip, terms: terms, priority: priority)
    }
}

let parakeet = PinnedModel(parakeet: ParakeetTranscriber(paths: .forBundle(id: AppPaths.devBundleID)))

func installModel(into folder: URL) async -> Int32 {
    guard let access = CloudAccess.granted(by: .defaults, app: .unknown, keys: { _ in nil }) else { return 1 }
    do {
        let shown = Mutex(-1)
        try await ParakeetTranscriber.install(paths: AppPaths(root: folder), access: access) { fraction in
            let percent = Int(fraction * 100)
            let changed = shown.withLock { last in
                defer { last = percent }
                return last != percent
            }
            guard changed else { return }
            FileHandle.standardError.write(Data("\rinstalling: \(percent)%".utf8))
        }
        FileHandle.standardError.write(Data("\ninstalled\n".utf8))
        return 0
    } catch {
        return fail("install failed: \(error)")
    }
}

func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("lexicon-eval: \(message)\n".utf8))
    return 1
}

func usage() -> Int32 {
    FileHandle.standardError.write(Data("""
        usage: lexicon-eval <wav> [--scripted <text>]
               lexicon-eval --manifest <manifest.jsonl> [--split <name>] [--baseline <run.jsonl>]
                            [--out <run.jsonl>] [--scripted-gold]
               lexicon-eval --install-model <data folder>

        """.utf8))
    return 2
}

exit(await runEval(arguments: CommandLine.arguments))
