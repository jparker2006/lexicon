import Foundation
import Testing
@testable import LexiconEval

private let guardScanExecutable = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: ".build/debug/lexicon-eval")

private func runGuardScanExecutable(on manifest: URL) async throws -> (status: Int32, output: String) {
    try await runChild(guardScanExecutable, ["--guard-scan", manifest.path(percentEncoded: false)])
}

@Test func guardScanCountsPresentTextAndPrintsOnlyAggregateCounts() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rows: [[String: Any]] = [
        [
            "id": "ordinary-row", "audio_filepath": "missing/ordinary.wav",
            "text": "Please review the deployment notes this afternoon.",
            "gold": "review", "split": "everyday", "session": "shared-review-session",
        ],
        [
            "id": "matching-row", "audio_filepath": "missing/matching.wav",
            "text": "Please keep qjvmxkztbdrphwnslfygcauo private.",
            "gold": "agreed", "split": "everyday", "session": "shared-review-session",
        ],
        [
            "id": "empty-row", "audio_filepath": "missing/empty.wav", "text": "",
            "gold": "review", "split": "held-back", "session": "held-back-review-session",
        ],
        [
            "id": "missing-text-row", "audio_filepath": "missing/missing-text.wav",
            "gold": "agreed", "split": "everyday", "session": "session-missing-text",
        ],
        [
            "id": "null-text-row", "audio_filepath": "missing/null-text.wav", "text": NSNull(),
            "gold": "agreed", "split": "everyday", "session": "session-null-text",
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

    #expect(FileManager.default.isExecutableFile(atPath: guardScanExecutable.path(percentEncoded: false)))
    let result = try await runGuardScanExecutable(on: manifest)
    #expect(result.status == 0)
    #expect(result.output == "scanned=3 matched=1\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted() == originalContents)
}

@Test func guardScanReportsZeroMatchesWithoutThresholdingAndHandlesTextlessManifests() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let nonmatching = directory.appending(path: "nonmatching.jsonl")
    try "{\"id\":\"plain-row\",\"text\":\"Ordinary synthetic notes.\"}\n\n{\"id\":\"null-row\",\"text\":null}\r\n{\"id\":\"missing-row\"}"
        .write(to: nonmatching, atomically: true, encoding: .utf8)
    let textless = directory.appending(path: "textless.jsonl")
    try "{\"id\":\"missing-row\"}\r\n{\"id\":\"null-row\",\"text\":null}"
        .write(to: textless, atomically: true, encoding: .utf8)
    let empty = directory.appending(path: "empty.jsonl")
    try "".write(to: empty, atomically: true, encoding: .utf8)
    let whitespace = directory.appending(path: "whitespace.jsonl")
    try " \t\r\n\n".write(to: whitespace, atomically: true, encoding: .utf8)
    let originalContents = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()

    for (manifest, expected) in [
        (nonmatching, "scanned=1 matched=0\n"),
        (textless, "scanned=0 matched=0\n"),
        (empty, "scanned=0 matched=0\n"),
        (whitespace, "scanned=0 matched=0\n"),
    ] {
        #expect(await runEval(arguments: ["lexicon-eval", "--guard-scan", manifest.path(percentEncoded: false)]) == 0)
        let result = try await runGuardScanExecutable(on: manifest)
        #expect(result.status == 0)
        #expect(result.output == expected)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted() == originalContents)
}

@Test func guardScanRejectsConflictsThroughDispatchAndExecutable() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "synthetic.jsonl").path(percentEncoded: false)
    let missing = directory.appending(path: "missing.jsonl").path(percentEncoded: false)
    let missingFile = directory.appending(path: "missing.txt").path(percentEncoded: false)
    let tempFolder = directory.appending(path: "import-target").path(percentEncoded: false)
    let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let repoOutput = repo.appending(path: ".build/guard-scan-conflict-output.jsonl").path(percentEncoded: false)
    let guardMode = ["--guard-scan", path]
    var cases = [["--guard-scan"], ["--guard-scan", "--out"], guardMode + guardMode,
                 guardMode + ["--scripted-gold"], ["--scripted-gold"] + guardMode]
    for valueOption in [
        ["--scripted", "synthetic transcript"], ["--manifest", missing], ["--split", "everyday"],
        ["--baseline", missingFile], ["--out", missingFile], ["--lexicon", missingFile],
        ["--sample", "1"], ["--pace", "fast"], ["--into", tempFolder],
        ["--transcribe", missing, "--out", repoOutput],
        ["--install-model", "org.example/model"],
        ["--import-lexicon", missingFile, "--into", tempFolder],
    ] {
        cases += [guardMode + valueOption, valueOption + guardMode]
    }
    let wav = directory.appending(path: "missing.wav").path(percentEncoded: false)
    cases += [guardMode + [wav], [wav] + guardMode]

    #expect(FileManager.default.isExecutableFile(atPath: guardScanExecutable.path(percentEncoded: false)))
    for arguments in cases {
        #expect(await runEval(arguments: ["lexicon-eval"] + arguments) == 2)
        let result = try await runChild(guardScanExecutable, arguments)
        #expect(result.status == 2)
        #expect(result.output.hasPrefix("usage: lexicon-eval "))
        #expect(!result.output.contains(directory.path(percentEncoded: false)))
    }
}

@Test func guardScanExecutableHidesUnreadableAndMalformedManifests() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let validRow = Data("{\"id\":\"synthetic-valid-row\",\"text\":\"ordinary synthetic words\"}\n".utf8)
    let invalidLines: [(String, Data)] = [
        ("bad-json", Data("{\"id\":\"synthetic-row\",\"text\":".utf8)),
        ("top-array", Data("[]\n".utf8)), ("top-null", Data("null\n".utf8)),
        ("text-number", Data("{\"text\":17}\n".utf8)),
        ("text-object", Data("{\"text\":{}}\n".utf8)),
        ("text-bool", Data("{\"id\":\"synthetic-row\",\"text\":true}\n".utf8)),
        ("text-array", Data("{\"id\":\"synthetic-row\",\"text\":[]}\n".utf8)),
        ("bad-utf8", Data([0xFF, 0xFE, 0xFD])),
    ]
    var paths = [directory.path(percentEncoded: false)] // A directory cannot be read as a manifest.
    for (name, suffix) in invalidLines {
        var data = validRow // A later bad line must suppress every partial count.
        data.append(suffix)
        let url = directory.appending(path: "\(name).jsonl")
        try data.write(to: url)
        paths.append(url.path(percentEncoded: false))
    }
    paths.append(directory.appending(path: "absent.jsonl").path(percentEncoded: false))
    for path in paths {
        let result = try await runChild(guardScanExecutable, ["--guard-scan", path])
        #expect(result.status == 1)
        #expect(result.output == "lexicon-eval: cannot scan manifest\n")
    }
}
