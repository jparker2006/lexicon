import Foundation
import AudioCapture
import LexiconCore
import Transcription
import WordStore

/// `lexicon-eval --manifest`: every entry of a split through the real headless
/// pipeline, then the scorer's report on the run.
///
/// The entries are chosen before Parakeet loads or any audio plays: one still in
/// Jake's gold review is skipped with its session, and a held-back one refuses
/// the run in its first second (`selectEntries`). `--sample <n>` runs the n lowest ids of the
/// rest, and the scorer scores the same n (`report --sample`): the quick eval's
/// realtime lag sample. `--pace fast` runs entries as fast as the pipeline
/// drains them, with no lag (a lag there would not be a measurement): the quick
/// eval's word and Term scores, for a local model only, since a cloud or
/// streaming engine hears at the speed of speech.
func evalManifest(_ manifest: URL, split: String?, sample: Int?, pace: FilePace, baseline: URL?, out: URL?,
                  lexicon: URL?, scriptedGold: Bool) async -> Int32 {
    if let out {
        guard mayWriteRun(to: out, manifest: manifest, lexicon: lexicon, repo: repo) else {
            return fail("--out is inside a git repo but the manifest or Lexicon is not public; private text never goes in a repo")
        }
        // Never over a manifest, a baseline or another run: they may be Jake's data.
        guard !FileManager.default.fileExists(atPath: out.path(percentEncoded: false)) else { return fail("--out already exists") }
    }
    let selection: ManifestSelection
    do { selection = try selectEntries(from: manifest, split: split, sample: sample) } catch { return fail("\(error)") }
    if selection.leftOut > 0 {
        FileHandle.standardError.write(Data("""
            lexicon-eval: skipping \(selection.leftOut) entries left out in review; answer them with \(reviewCommand)

            """.utf8))
    }
    let entries: [LexiconEntry]
    do { entries = try readLexicon(lexicon) } catch { return fail("cannot read the Lexicon file: \(error.localizedDescription)") }
    if !scriptedGold { await warmParakeet() }
    let lines: [RunLine]
    do {
        lines = try await runManifest(selection, pace: pace, lexicon: entries) { entry in
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
    do { try writeRun(pace == .realtime ? lines : lines.map(\.withoutLag), to: runFile) } catch { return fail("\(error)") }

    // A false alarm counts against the gold entry's Terms and the whole Lexicon, so
    // the Lexicon's written forms go to the scorer in a file of their own.
    let termsFile = FileManager.default.temporaryDirectory.appending(path: "lexicon-terms-\(UUID().uuidString).txt")
    defer { if lexicon != nil { try? FileManager.default.removeItem(at: termsFile) } }

    var arguments = [repo.appending(path: "scorer/score").path(percentEncoded: false), "report", "--gold", manifest.path(percentEncoded: false),
                     "--run", runFile.path(percentEncoded: false)]
    if let split { arguments += ["--split", split] }
    if let sample { arguments += ["--sample", String(sample)] }
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
    do { return try await exitStatus(of: scorer) } catch { return fail("cannot start the scorer: \(error.localizedDescription)") }
}

/// Runs `process` to its end without blocking a thread in waitUntilExit, which
/// spins the run loop under Swift concurrency.
func exitStatus(of process: Process) async throws -> Int32 {
    try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
}
