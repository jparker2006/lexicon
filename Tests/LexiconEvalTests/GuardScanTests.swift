import Foundation
import Testing
@testable import LexiconEval

@Test func guardScanCountsPresentTextAndPrintsOnlyAggregateCounts() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rows: [[String: Any]] = [
        [
            "id": "ordinary-row", "audio_filepath": "missing/ordinary.wav",
            "text": "Please review the deployment notes this afternoon.",
            "gold": "review", "split": "held-back", "session": "session-ordinary",
        ],
        [
            "id": "matching-row", "audio_filepath": "missing/matching.wav",
            "text": "Please keep qjvmxkztbdrphwnslfygcauo private.",
            "gold": "review", "split": "held-back", "session": "session-matching",
        ],
        [
            "id": "empty-row", "audio_filepath": "missing/empty.wav", "text": "",
            "gold": "review", "split": "held-back", "session": "session-empty",
        ],
        [
            "id": "missing-text-row", "audio_filepath": "missing/missing-text.wav",
            "gold": "review", "split": "held-back", "session": "session-missing-text",
        ],
        [
            "id": "null-text-row", "audio_filepath": "missing/null-text.wav", "text": NSNull(),
            "gold": "review", "split": "held-back", "session": "session-null-text",
        ],
    ]
    let manifest = directory.appending(path: "manifest.jsonl")
    let lines = try rows.map { row in
        String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self)
    }
    try (lines.joined(separator: "\n") + "\n").write(to: manifest, atomically: true, encoding: .utf8)
    let originalContents = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()

    let arguments = ["lexicon-eval", "--guard-scan", manifest.path(percentEncoded: false)]
    #expect(await runEval(arguments: arguments) == 0)

    let repository = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let executable = repository.appending(path: ".build/debug/lexicon-eval")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)))
    let result = try await runChild(executable, ["--guard-scan", manifest.path(percentEncoded: false)])
    #expect(result.status == 0)
    #expect(result.output == "scanned=3 matched=1\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted() == originalContents)
}
