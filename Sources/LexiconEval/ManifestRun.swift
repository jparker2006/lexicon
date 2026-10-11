import Foundation
import LexiconDomain
import LexiconCore
import AudioCapture
import Transcription

/// One manifest line: NeMo-style (`audio_filepath`, `text`, `duration`) plus
/// Lexicon's `session`, `terms`, `speech_end`, `context` and `split`. The scorer
/// reads `text`, `session`, `terms` and `split` from the same file; the run needs
/// only these. `terms` are the Terms said, the answer key: they never reach the
/// engine, which gets its Terms from the Lexicon like a live Dictation.
struct ManifestEntry: Decodable, Sendable {
    let id: String
    let audioFilepath: String
    let text: String
    /// Bundle ID of the app Jake was dictating into.
    let context: String?
    let split: String?

    enum CodingKeys: String, CodingKey {
        case id, text, context, split
        case audioFilepath = "audio_filepath"
    }
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
    let lagMS: Int?
    let cleanup: String?
    /// The speech model whose text won.
    let engine: String?
    let lost: Bool

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
    case missingAudio(id: String)
    case setup(String)

    var description: String {
        switch self {
        case .unreadableManifest(let why): "cannot read the manifest: \(why)"
        case .badLine(let n, let why): "manifest line \(n): \(why)"
        case .noEntries(let split): split.map { "no manifest entries in split \($0)" } ?? "the manifest is empty"
        case .missingAudio(let id): "entry \(id): audio file not found"
        case .setup(let why): "headless setup failed: \(why)"
        }
    }
}

/// Runs every entry (of `split`, when given) through the real headless pipeline,
/// one at a time and in manifest order, each in its own temporary History that
/// is deleted after. `engine` gives the speech model for an entry: the local
/// model, a scripted fake, or nil for none. Every audio file is checked before
/// the first entry runs, so a broken manifest fails in seconds, not mid-run.
func runManifest(_ manifest: URL, split: String?, pace: FilePace,
                 engine: (ManifestEntry) -> (any LocalTranscriber)?,
                 progress: (Int, Int) -> Void = { _, _ in }) async throws -> [RunLine] {
    let entries = try readManifest(manifest).filter { split == nil || $0.split == split }
    guard !entries.isEmpty else { throw EvalError.noEntries(split: split) }
    let folder = manifest.deletingLastPathComponent()
    let audio = try entries.map { entry in
        let url = URL(filePath: entry.audioFilepath, relativeTo: folder).absoluteURL
        guard FileManager.default.fileExists(atPath: url.path()) else { throw EvalError.missingAudio(id: entry.id) }
        return url
    }

    var lines: [RunLine] = []
    for (entry, wav) in zip(entries, audio) {
        progress(lines.count, entries.count)
        lines.append(try await run(entry, wav: wav, pace: pace, local: engine(entry)))
    }
    progress(lines.count, entries.count)
    return lines
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
            throw EvalError.badLine(index + 1, "not a manifest entry with id, audio_filepath and text")
        }
    }
    return entries
}

private func run(_ entry: ManifestEntry, wav: URL, pace: FilePace,
                 local: (any LocalTranscriber)?) async throws -> RunLine {
    let paths = AppPaths.temporary()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let context = AppContext(bundleID: entry.context, appName: nil, windowTitle: nil, workingDirectory: nil)
    let system: HeadlessSystem
    do {
        system = try HeadlessSystem.make(paths: paths, context: context, preferences: .defaults, local: local)
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

/// Run files hold text from the Test set, so one may go inside the repo only
/// when the manifest is inside it too (the public fixtures). Paths compare by
/// component, case-insensitively, since APFS is.
func mayWriteRun(to out: URL, manifest: URL, repo: URL) -> Bool {
    func components(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
    }
    func inside(_ url: URL) -> Bool { components(url).starts(with: components(repo)) }
    return !inside(out) || inside(manifest)
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
