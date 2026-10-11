import Foundation
import LexiconDomain
import LexiconCore
import LocalParakeet
import Transcription
import WordStore

// `lexicon-eval`: dev tool, never shipped. Runs the real Conductor headless, at
// the speed of speech, on one WAV or on every entry of a manifest.
//
//   swift run lexicon-eval <wav> [--scripted <text>] [--lexicon <file>]
//       {"status": "inserted", "text": "...", "lag_ms": 42}
//
//   swift run lexicon-eval --manifest <manifest.jsonl> [--split <name>]
//       [--baseline <run.jsonl>] [--out <run.jsonl>] [--scripted-gold] [--lexicon <file>]
//       the report from `scorer/score report` (see scorer/README.md)
//
//   swift run lexicon-eval --transcribe <manifest.jsonl> --out <run.jsonl>
//       the speech text of every entry, as draft gold (see below)
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
// `--lexicon <file>` imports a Lexicon file (the app's import format) into every
// Dictation, and a manifest run counts false alarms against its words too.
//
// A manifest run writes one run line per entry (`--out` keeps the file; it is
// what a later run's `--baseline` reads), then passes it to the scorer and exits
// with the scorer's code: 0, or 3 when a score got worse than the baseline.
// The quick run is `--split everyday`; the full run is `--split held-back`.
//
// `--transcribe` makes the draft gold for the Test set (scorer/testset): local
// Parakeet's speech text for every entry, so the manifest needs no `text`. No
// gold is read and no scorer runs. Only the text matters there, so entries run
// at fast pace and carry no `lag_ms`: it would not be a measurement. It runs in
// Private mode, so nothing leaves the Mac even with keys set.
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
        case "--scripted", "--manifest", "--split", "--baseline", "--out", "--install-model", "--transcribe", "--lexicon":
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
    if let manifest = options["--transcribe"] {
        guard let out = options["--out"], files.isEmpty, !scriptedGold,
              options.keys.allSatisfy({ $0 == "--transcribe" || $0 == "--out" }) else { return usage() }
        return await transcribe(URL(filePath: manifest), out: URL(filePath: out))
    }
    if let manifest = options["--manifest"] {
        guard files.isEmpty, options["--scripted"] == nil else { return usage() }
        return await evalManifest(URL(filePath: manifest), split: options["--split"],
                                  baseline: options["--baseline"].map { URL(filePath: $0) },
                                  out: options["--out"].map { URL(filePath: $0) },
                                  lexicon: options["--lexicon"].map { URL(filePath: $0) }, scriptedGold: scriptedGold)
    }
    guard files.count == 1, options.keys.allSatisfy({ $0 == "--scripted" || $0 == "--lexicon" }), !scriptedGold else {
        return usage()
    }
    return await evalFile(URL(filePath: files[0]), scripted: options["--scripted"],
                          lexicon: options["--lexicon"].map { URL(filePath: $0) })
}

func evalFile(_ wav: URL, scripted: String?, lexicon: URL?) async -> Int32 {
    let entries: [LexiconEntry]
    do { entries = try readLexicon(lexicon) } catch { return fail("cannot read the Lexicon file: \(error.localizedDescription)") }
    let paths = AppPaths.temporary()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let system: HeadlessSystem
    do {
        system = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                                         local: scripted.map(ScriptedTranscriber.init(text:)) ?? parakeet)
        if !entries.isEmpty { _ = try await system.lexicon.add(entries) }
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

func evalManifest(_ manifest: URL, split: String?, baseline: URL?, out: URL?, lexicon: URL?,
                  scriptedGold: Bool) async -> Int32 {
    if let out {
        guard mayWriteRun(to: out, manifest: manifest, lexicon: lexicon, repo: repo) else {
            return fail("--out is inside a git repo but the manifest or Lexicon is not public; private text never goes in a repo")
        }
        // Never over a manifest, a baseline or another run: they may be Jake's data.
        guard !FileManager.default.fileExists(atPath: out.path(percentEncoded: false)) else { return fail("--out already exists") }
    }
    let entries: [LexiconEntry]
    do { entries = try readLexicon(lexicon) } catch { return fail("cannot read the Lexicon file: \(error.localizedDescription)") }
    let lines: [RunLine]
    do {
        lines = try await runManifest(manifest, split: split, pace: .realtime, lexicon: entries) { entry in
            scriptedGold ? ScriptedTranscriber(text: entry.text ?? "") as any LocalTranscriber : parakeet
        } progress: { done, total in
            FileHandle.standardError.write(Data("lexicon-eval: \(done)/\(total)\r".utf8))
        }
    } catch {
        return fail("\(error)")
    }
    FileHandle.standardError.write(Data("\n".utf8))

    let runFile = out ?? FileManager.default.temporaryDirectory.appending(path: "lexicon-run-\(UUID().uuidString).jsonl")
    defer { if out == nil { try? FileManager.default.removeItem(at: runFile) } }
    do { try writeRun(lines, to: runFile) } catch { return fail("\(error)") }

    // A false alarm counts against the gold entry's Terms and the whole Lexicon, so
    // the Lexicon's written forms go to the scorer in a file of their own.
    let termsFile = FileManager.default.temporaryDirectory.appending(path: "lexicon-terms-\(UUID().uuidString).txt")
    defer { if lexicon != nil { try? FileManager.default.removeItem(at: termsFile) } }

    var arguments = [repo.appending(path: "scorer/score").path(percentEncoded: false), "report", "--gold", manifest.path(percentEncoded: false),
                     "--run", runFile.path(percentEncoded: false)]
    if let split { arguments += ["--split", split] }
    if let baseline { arguments += ["--baseline", baseline.path(percentEncoded: false)] }
    if lexicon != nil {
        do { try await writtenForms(entries).write(to: termsFile, atomically: true, encoding: .utf8) } catch {
            return fail("cannot write the Lexicon's written forms: \(error.localizedDescription)")
        }
        arguments += ["--terms", termsFile.path(percentEncoded: false)]
    }
    let scorer = Process()
    scorer.executableURL = URL(filePath: "/bin/sh")
    scorer.arguments = arguments
    do { try scorer.run() } catch { return fail("cannot start the scorer: \(error.localizedDescription)") }
    scorer.waitUntilExit()
    return scorer.terminationStatus
}

func transcribe(_ manifest: URL, out: URL) async -> Int32 {
    guard mayWriteRun(to: out, manifest: manifest, repo: repo) else {
        return fail("--out is inside a git repo but the manifest is not public; Test set text never goes in a repo")
    }
    do {
        try await transcribeManifest(manifest, to: out) { _ in parakeet } progress: { done, total in
            FileHandle.standardError.write(Data("lexicon-eval: \(done)/\(total)\r".utf8))
        }
    } catch {
        return fail("\(error)")
    }
    FileHandle.standardError.write(Data("\n".utf8))
    return 0
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
        try await ParakeetTranscriber.install(paths: AppPaths(root: folder), access: access) { fraction in
            FileHandle.standardError.write(Data("\rinstalling: \(Int(fraction * 100))%".utf8))
        }
        FileHandle.standardError.write(Data("\ninstalled\n".utf8))
        return 0
    } catch {
        return fail("install failed: \(error)")
    }
}

/// The `--lexicon` file, read once before a run. Only its counts go to stderr,
/// never an entry: the file may be Jake's starter Lexicon.
func readLexicon(_ url: URL?) throws -> [LexiconEntry] {
    guard let url else { return [] }
    let file = try LexiconFile(contentsOf: url)
    let terms = file.entries.count(where: { if case .term = $0 { true } else { false } })
    var report = "lexicon-eval: Lexicon: \(terms) Terms, \(file.entries.count - terms) Rules"
    if file.unreadable > 0 { report += ", \(file.unreadable) lines not read" }
    FileHandle.standardError.write(Data((report + "\n").utf8))
    return file.entries
}

/// The written forms of the Lexicon the file imports to, each once, one per
/// line: a Term's text and a Rule's written side. The scorer's `--terms` file.
/// Read back from a store, so a Term listed twice in another case is one Term,
/// as it is in the app.
func writtenForms(_ entries: [LexiconEntry]) async throws -> String {
    let paths = AppPaths.temporary()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let lexicon = try Lexicon(paths: paths)
    _ = try await lexicon.add(entries)
    var seen = Set<String>()
    var body = ""
    for entry in await lexicon.entries {
        let form = switch entry {
        case .term(let term): term.text
        case .rule(let rule): rule.written
        }
        if seen.insert(form).inserted { body += form + "\n" }
    }
    return body
}

func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("lexicon-eval: \(message)\n".utf8))
    return 1
}

func usage() -> Int32 {
    FileHandle.standardError.write(Data("""
        usage: lexicon-eval <wav> [--scripted <text>] [--lexicon <file>]
               lexicon-eval --manifest <manifest.jsonl> [--split <name>] [--baseline <run.jsonl>]
                            [--out <run.jsonl>] [--scripted-gold] [--lexicon <file>]
               lexicon-eval --transcribe <manifest.jsonl> --out <run.jsonl>
               lexicon-eval --install-model <data folder>

        """.utf8))
    return 2
}

exit(await runEval(arguments: CommandLine.arguments))
