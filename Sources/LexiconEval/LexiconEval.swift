import Foundation
import AudioCapture
import LexiconDomain
import LexiconCore
import LocalParakeet
import Transcription
import WordStore

// `lexicon-eval`: dev tool, never shipped. Its main is Sources/LexiconEvalCLI, one
// line, so the tests can import everything here: a test target never links an
// executable (scripts/checks/21-source-lints.sh). Runs the real Conductor
// headless, at the speed of speech, on one WAV or on every entry of a manifest.
//
//   swift run lexicon-eval <wav> [--scripted <text>] [--lexicon <file>]
//       {"status": "inserted", "text": "...", "lag_ms": 42}
//
//   swift run lexicon-eval --manifest <manifest.jsonl> [--split <name>] [--sample <n>] [--pace fast]
//       [--baseline <run.jsonl>] [--out <run.jsonl>] [--scripted-gold] [--lexicon <file>]
//       the report from `scorer/score report` (see scorer/README.md and EvalManifest.swift)
//
//   swift run lexicon-eval --transcribe <manifest.jsonl> --out <run.jsonl>
//       the speech text of every entry, as draft gold (see below)
//
//   swift run lexicon-eval --install-model <bundle id>
//       downloads the local model into that app's `<data folder>/models/`,
//       unless Private mode is on in that app's settings
//       (`scripts/install-model.sh` runs it; first-run setup installs it in the app)
//
//   swift run lexicon-eval --import-lexicon <file> --into <data folder>
//       imports a Lexicon file into `<data folder>/lexicon.sqlite`, as the
//       page's Import does (`scripts/import-lexicon.sh` runs it at install)
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
// Entries still in Jake's gold review are skipped before any audio plays, and a
// held-back one refuses the run. The quick eval is `scripts/eval-quick.sh`; the
// full run is `--split held-back`.
//
// `--transcribe` makes the draft gold for the Test set (scorer/testset): local
// Parakeet's speech text for every entry, so the manifest needs no `text`. No
// gold is read and no scorer runs. Only the text matters there, so entries run
// at fast pace and carry no `lag_ms`: it would not be a measurement. It runs in
// Private mode, so nothing leaves the Mac even with keys set.
//
// Keys come from LEXICON_KEY_* environment variables (Secrets(.environment)).
// History and audio go to temporary folders deleted after each Dictation, never
// to an app's data folder. Only `--install-model` and `--import-lexicon` write
// into one, the folder they are given.

/// This checkout: the scorer lives here, and only a manifest inside it is public
/// (`mayWriteRun`).
let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

struct Line: Encodable {
    let status: String
    let text: String?
    let lag_ms: Int?
}

/// Runs `lexicon-eval` with these arguments (the first is the tool's own path)
/// and returns its exit code.
public func runEval(arguments: [String]) async -> Int32 {
    if arguments.dropFirst().contains("--guard-scan") {
        guard arguments.count == 3, arguments[1] == "--guard-scan", !arguments[2].hasPrefix("--") else {
            return usage()
        }
        return guardScan(URL(filePath: arguments[2]))
    }
    var options: [String: String] = [:]
    var scriptedGold = false
    var files: [String] = []
    var rest = arguments.dropFirst()
    while let argument = rest.popFirst() {
        switch argument {
        case "--scripted-gold": scriptedGold = true
        case "--scripted", "--manifest", "--split", "--baseline", "--out", "--install-model", "--transcribe", "--lexicon",
             "--import-lexicon", "--into", "--sample", "--pace":
            guard let value = rest.popFirst(), options[argument] == nil else { return usage() }
            options[argument] = value
        default:
            guard !argument.hasPrefix("--") else { return usage() }
            files.append(argument)
        }
    }
    if let bundleID = options["--install-model"] {
        guard options.count == 1, files.isEmpty, !scriptedGold, bundleID.contains("."), !bundleID.hasPrefix("."), !bundleID.contains("/")
        else { return usage() }
        return await installModel(for: bundleID)
    }
    if let file = options["--import-lexicon"] {
        guard let folder = options["--into"], options.count == 2, files.isEmpty, !scriptedGold else { return usage() }
        return await importLexicon(URL(filePath: file), into: URL(filePath: folder, directoryHint: .isDirectory))
    }
    if let manifest = options["--transcribe"] {
        guard let out = options["--out"], files.isEmpty, !scriptedGold,
              options.keys.allSatisfy({ $0 == "--transcribe" || $0 == "--out" }) else { return usage() }
        return await transcribe(URL(filePath: manifest), out: URL(filePath: out))
    }
    if let manifest = options["--manifest"] {
        let pace: FilePace? = switch options["--pace"] {
        case nil, "realtime": .realtime
        case "fast": .asFastAsPossible
        default: nil
        }
        let sample = options["--sample"].map { Int($0) ?? 0 }
        guard files.isEmpty, options["--scripted"] == nil, let pace, (sample ?? 1) > 0 else { return usage() }
        return await evalManifest(URL(filePath: manifest), split: options["--split"], sample: sample, pace: pace,
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
    if scripted == nil { await warmParakeet() }
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

func transcribe(_ manifest: URL, out: URL) async -> Int32 {
    guard mayWriteRun(to: out, manifest: manifest, repo: repo) else {
        return fail("--out is inside a git repo but the manifest is not public; Test set text never goes in a repo")
    }
    await warmParakeet()
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
    func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        parakeet.session(terms: terms, priority: priority)
    }
}

let parakeet = PinnedModel(parakeet: ParakeetTranscriber(paths: .forBundle(id: AppPaths.devBundleID)))

/// Loads Parakeet before the first clip, as the app does at launch. A new
/// executable's first load compiles for about 25 s, which would otherwise land
/// on the first clip's lag, or past fn-up's 2 s wait and leave it waiting.
/// A missing model is not an error here: each clip then reports it.
func warmParakeet() async {
    FileHandle.standardError.write(Data("lexicon-eval: loading Parakeet\r".utf8))
    try? await parakeet.load()
}

/// The page's Import, from a shell: the same store call, so a second run adds
/// nothing. Prints counts only, never an entry: the file may be Jake's starter
/// Lexicon. A running app reads the Lexicon at launch, so import before
/// `scripts/install.sh` relaunches it.
func importLexicon(_ file: URL, into folder: URL) async -> Int32 {
    let counts: ImportCounts
    do {
        counts = try await Lexicon(paths: AppPaths(root: folder)).add(contentsOf: file)
    } catch {
        return fail("import failed: \(error.localizedDescription)")
    }
    print("""
        lexicon-eval: imported \(counts.terms) Terms and \(counts.rules) Rules; \
        \(counts.duplicates) already in the Lexicon; \(counts.unreadable) \(counts.unreadable == 1 ? "line" : "lines") not read
        """)
    return 0
}

/// The app's own saved settings decide: with Private mode on in it, its model
/// install opens no connection, the same as an install the app would run.
func installModel(for bundleID: String) async -> Int32 {
    guard let access = PreferencesStore.modelInstallAccess(forApp: bundleID) else {
        return fail("Private mode is on in \(bundleID): turn it off to download the model")
    }
    do {
        try await ParakeetTranscriber.install(paths: .forBundle(id: bundleID), access: access) { fraction in
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
    if file.unreadable > 0 { report += ", \(file.unreadable) \(file.unreadable == 1 ? "line" : "lines") not read" }
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
               lexicon-eval --manifest <manifest.jsonl> [--split <name>] [--sample <n>] [--pace fast | realtime]
                            [--baseline <run.jsonl>] [--out <run.jsonl>] [--scripted-gold] [--lexicon <file>]
               lexicon-eval --transcribe <manifest.jsonl> --out <run.jsonl>
               lexicon-eval --install-model <bundle id>
               lexicon-eval --import-lexicon <file> --into <data folder>
               lexicon-eval --guard-scan <manifest.jsonl>

        """.utf8))
    return 2
}
