import Foundation
import LexiconDomain
import LexiconCore
import AudioCapture
import Transcription
import WordStore

/// One manifest line: NeMo-style (`audio_filepath`, `text`, `duration`) plus
/// Lexicon's `session`, `terms`, `speech_end`, `context`, `split` and `gold`. The
/// scorer reads `text`, `session`, `terms`, `split` and `gold` from the same file;
/// the run needs only these. `terms` are the Terms said, the answer key: they never reach the
/// engine, which gets its Terms from the Lexicon like a live Dictation.
struct ManifestEntry: Decodable, Sendable {
    let id: String
    let audioFilepath: String
    /// The gold text. Absent from a `--transcribe` manifest, which makes the draft gold.
    let text: String?
    /// Bundle ID of the app Jake was dictating into.
    let context: String?
    let split: String?
    let session: String?
    /// "review" while Jake's gold review (#51) has not answered it: its text is
    /// only a draft, so it is never spoken for a score.
    let gold: String?

    enum CodingKeys: String, CodingKey {
        case id, text, context, split, session, gold
        case audioFilepath = "audio_filepath"
    }

    var inReview: Bool { gold == "review" }
    /// An entry with no session is a session of its own, as in the scorer.
    var sessionKey: String { session.map { "s:\($0)" } ?? "id:\(id)" }
}

/// One Dictation's result, as the scorer reads it (`scorer/score report`).
/// A Dictation with no text scores as empty text: every word and Term missed.
struct RunLine: Codable, Equatable, Sendable {
    let id: String
    /// The Dictation's status, or "nothing" when no capture started.
    let status: String
    let speechText: String
    /// What was typed; empty unless the status is "inserted".
    let insertedText: String
    /// End of audio to text typed, headless.
    var lagMS: Int?
    let cleanup: String?
    /// The speech model whose text won.
    let engine: String?
    let lost: Bool

    /// At fast pace a lag would not be a measurement.
    var withoutLag: RunLine {
        var line = self
        line.lagMS = nil
        return line
    }

    enum CodingKeys: String, CodingKey {
        case id, status, cleanup, engine, lost
        case speechText = "speech_text"
        case insertedText = "inserted_text"
        case lagMS = "lag_ms"
    }
}

enum EvalError: Error, CustomStringConvertible {
    case unreadableManifest(String)
    case badLine(Int, String)
    case noEntries(split: String?)
    case nothingOutOfReview(Int)
    case heldBackInReview(Int)
    case missingAudio(id: String)
    case setup(String)
    case outExists
    case unwritableRun(String)

    var description: String {
        switch self {
        case .unreadableManifest(let why): "cannot read the manifest: \(why)"
        case .badLine(let n, let why): "manifest line \(n): \(why)"
        case .noEntries(let split): split.map { "no manifest entries in split \($0)" } ?? "the manifest is empty"
        case .nothingOutOfReview(let count):
            "all \(count) entries are left out in review; answer them with \(reviewCommand)"
        case .heldBackInReview(let count):
            "\(count) held-back entries are still in review, and held-back runs only whole; answer them with \(reviewCommand)"
        case .missingAudio(let id): "entry \(id): audio file not found"
        case .setup(let why): "headless setup failed: \(why)"
        case .outExists: "--out already exists"
        case .unwritableRun(let why): "cannot write the run file: \(why)"
        }
    }
}

let reviewCommand = "scripts/test-set.sh review"

/// The entries a run speaks, with their audio files, chosen before any audio
/// plays.
struct ManifestSelection: Sendable {
    let entries: [ManifestEntry]
    let audio: [URL]
    /// Entries of the split left out in review: the ones still to answer and
    /// every other entry in their sessions.
    let leftOut: Int
}

/// The entries of `split` (all, when nil) to run, in manifest order, by the
/// scorer's rule (scorer/lexicon_scorer/baselines.py gold_state): an entry still
/// in review is skipped with every other entry in its session, since the scorer
/// counts a session only once all of it is gold, and one in held-back refuses
/// the run, since held-back checks milestones and is scored only whole.
/// `sample` keeps the `sample` lowest ids of the rest, the draw
/// `scorer/score report --sample` scores. Every audio file is checked here too,
/// so a broken manifest fails in seconds, not mid-run.
func selectEntries(from manifest: URL, split: String?, sample: Int? = nil) throws -> ManifestSelection {
    let inSplit = try readManifest(manifest).filter { split == nil || $0.split == split }
    guard !inSplit.isEmpty else { throw EvalError.noEntries(split: split) }
    let heldBack = inSplit.count { $0.inReview && $0.split == "held-back" }
    guard heldBack == 0 else { throw EvalError.heldBackInReview(heldBack) }
    let open = Set(inSplit.filter(\.inReview).map(\.sessionKey))
    var entries = inSplit.filter { !open.contains($0.sessionKey) }
    guard !entries.isEmpty else { throw EvalError.nothingOutOfReview(inSplit.count) }
    if let sample {
        let drawn = Set(entries.map(\.id).sorted().prefix(sample))
        entries = entries.filter { drawn.contains($0.id) }
    }
    let folder = manifest.deletingLastPathComponent()
    let audio = try entries.map { entry in
        let url = URL(filePath: entry.audioFilepath, relativeTo: folder).absoluteURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { throw EvalError.missingAudio(id: entry.id) }
        return url
    }
    return ManifestSelection(entries: entries, audio: audio, leftOut: inSplit.count { open.contains($0.sessionKey) })
}

/// Runs every selected entry through the real headless pipeline, one at a time
/// and in manifest order, each in its own temporary History that is deleted
/// after. `engine` gives the speech model for an entry: the local model, a
/// scripted fake, or nil for none. `preferences` applies to every entry.
/// `lexicon` is imported into each entry's own temporary Lexicon, as the app's
/// Import would.
func runManifest(_ selection: ManifestSelection, pace: FilePace, preferences: Preferences = .defaults,
                 lexicon: [LexiconEntry] = [], engine: (ManifestEntry) -> (any LocalTranscriber)?,
                 progress: (Int, Int) -> Void = { _, _ in }) async throws -> [RunLine] {
    var lines: [RunLine] = []
    for (entry, wav) in zip(selection.entries, selection.audio) {
        progress(lines.count, selection.entries.count)
        lines.append(try await run(entry, wav: wav, pace: pace, preferences: preferences, lexicon: lexicon,
                                   local: engine(entry)))
    }
    progress(lines.count, selection.entries.count)
    return lines
}

/// `lexicon-eval --transcribe`: the speech text of every entry, as draft gold for
/// the Test set (scorer/testset). Only the text matters, so entries run at fast
/// pace and carry no lag. Private mode keeps the run off the network even
/// with keys set. No gold is read and no scorer runs.
func transcribeManifest(_ manifest: URL, to out: URL, engine: (ManifestEntry) -> (any LocalTranscriber)?,
                        progress: (Int, Int) -> Void = { _, _ in }) async throws {
    // Checked before the run. Never over an existing file: it may be Jake's.
    guard !FileManager.default.fileExists(atPath: out.path(percentEncoded: false)) else { throw EvalError.outExists }
    var preferences = Preferences.defaults
    preferences.privacy = .private
    let lines = try await runManifest(try selectEntries(from: manifest, split: nil), pace: .asFastAsPossible,
                                      preferences: preferences, engine: engine, progress: progress)
    try writeRun(lines.map(\.withoutLag), to: out)
}

/// One run line per entry, in the format the scorer reads (`scorer/score report --run`).
func writeRun(_ lines: [RunLine], to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        let body = try lines.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }.joined()
        try body.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        throw EvalError.unwritableRun(error.localizedDescription)
    }
}

private func readManifest(_ url: URL) throws -> [ManifestEntry] {
    let data: Data
    do { data = try Data(contentsOf: url) } catch { throw EvalError.unreadableManifest(error.localizedDescription) }
    var entries: [ManifestEntry] = []
    for (index, line) in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).enumerated() {
        guard !line.allSatisfy(\.isWhitespace) else { continue }
        do {
            entries.append(try JSONDecoder().decode(ManifestEntry.self, from: Data(line.utf8)))
        } catch {
            throw EvalError.badLine(index + 1, "not a manifest entry with id and audio_filepath (text, if present, a string)")
        }
    }
    return entries
}

private func run(_ entry: ManifestEntry, wav: URL, pace: FilePace, preferences: Preferences,
                 lexicon: [LexiconEntry], local: (any LocalTranscriber)?) async throws -> RunLine {
    let paths = AppPaths.temporary()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let context = AppContext(bundleID: entry.context, appName: nil, windowTitle: nil, workingDirectory: nil)
    let system: HeadlessSystem
    do {
        system = try HeadlessSystem.make(paths: paths, context: context, preferences: preferences, local: local)
        if !lexicon.isEmpty { _ = try await system.lexicon.add(lexicon) }
    } catch {
        throw EvalError.setup("\(error)")
    }
    let result = await system.conductor.dictate(file: wav, pace: pace)
    await system.history.flush()
    let row = await system.history.dictation(result.id)

    return RunLine(
        id: entry.id, status: result.status?.rawValue ?? "nothing",
        speechText: result.versions?.model ?? "",
        insertedText: result.status == .inserted ? result.versions?.cleaned ?? "" : "",
        lagMS: result.lag.map { Int($0 / .milliseconds(1)) },
        cleanup: result.cleanup.map(label), engine: result.model?.id,
        lost: isLost(reported: result.status, saved: row.map { ($0.status, $0.audio) }))
}

/// Lost: a Dictation was recorded, and now neither its text nor its audio is
/// kept. A waiting or failed Dictation with audio on disk is not lost: a retry
/// can still produce its text.
func isLost(reported: DictationStatus?, saved: (status: DictationStatus, audio: AudioStorage)?) -> Bool {
    guard reported != nil else { return false }
    guard let saved else { return true }
    return !saved.status.hasText && saved.audio != .onDisk
}

/// Run files hold text from the Test set, and typed text holds the written side
/// of any Rule that fired, so one may go inside a git work tree (this checkout,
/// the main one that holds the worktrees, any other) only when the manifest and
/// the `--lexicon` file are inside this repo too: the public fixtures. Paths
/// compare by component, case-insensitively, since APFS is.
func mayWriteRun(to out: URL, manifest: URL, lexicon: URL? = nil, repo: URL) -> Bool {
    func components(_ url: URL) -> [String] {
        url.absoluteURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
    }
    func inGitWorkTree(_ url: URL) -> Bool {
        var folder = url.absoluteURL.standardizedFileURL.resolvingSymlinksInPath()
        while folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: folder.appending(path: ".git").path(percentEncoded: false)) { return true }
        }
        return false
    }
    return !inGitWorkTree(out) || [manifest, lexicon].compactMap { $0 }.allSatisfy { components($0).starts(with: components(repo)) }
}

private func label(_ outcome: CleanupOutcome) -> String {
    switch outcome {
    case .aiAccepted(.cloud(let model)): "ai:\(model.rawValue)"
    case .aiAccepted(.onDevice): "ai:on-device"
    case .rulesOnly(.off): "rules-only:off"
    case .rulesOnly(.rejected(let failure)): "rules-only:rejected:\(failure.rawValue)"
    case .rulesOnly(.deadline): "rules-only:deadline"
    case .rulesOnly(.unavailable): "rules-only:unavailable"
    }
}
