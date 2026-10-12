#if DEBUG
import Foundation
import TestHooks

/// `lexicon-harness fixture <text>`: speaks `text` with the system voice into a
/// 16 kHz WAV in a `fixtures` folder, the kind `hook dictate` accepts, and
/// prints its path. The text itself is printed only as its length and hash, so
/// a result can be matched to its fixture without the text in any log.
func fixture(_ arguments: [String]) async throws {
    guard !arguments.isEmpty else { fail(usage, code: 64) }
    let text = arguments.joined(separator: " ")
    let fingerprint = Fingerprint(text)
    let folder = harnessFolder.appending(path: "fixtures", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let wav = folder.appending(path: "\(fingerprint.hash)-\(fingerprint.characters).wav")
    // `--` so a text starting with a dash is spoken, not read as an option; and
    // no `run`, whose error would print the text with the command line.
    let (status, _) = try await runChild("/usr/bin/say", ["-o", wav.path, "--file-format=WAVE", "--data-format=LEI16@16000", "--", text])
    guard status == 0 else { throw HarnessError("say exited \(status) for the fixture (\(fingerprint))") }
    print(wav.path)
    ok("fixture: \(fingerprint)")
}

/// Where the harness keeps its own files between runs: fixtures, the last checklist run.
let harnessFolder = FileManager.default.temporaryDirectory.appending(path: "lexicon-harness", directoryHint: .isDirectory)
#endif
