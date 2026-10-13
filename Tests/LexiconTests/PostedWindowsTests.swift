#if DEBUG
import Foundation
import Testing
@testable import TestHooks

// The windows the harness posts input in, which scripts/live-lane.sh idle
// skips (#225). The harness is the file's only writer: it appends one line
// per window and never rewrites what is there.

@Test func aWindowIsOneLineIdleReads() {
    #expect(PostedWindows.line(from: 1_760_000_000.25, to: 1_760_000_004.5, idle: 37.125) == "1760000000.250\t1760000004.500\t37.125\n")
}

@Test func aWindowAppendsAndKeepsEveryEarlierLine() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "posted-windows-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = PostedWindows.file(home: folder)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let earlier = (1...60).map { PostedWindows.line(from: Double($0), to: Double($0) + 1, idle: 0) }
    try earlier.joined().write(to: file, atomically: true, encoding: .utf8)

    PostedWindows.append(PostedWindows.line(from: 100, to: 101, idle: 2), to: file)

    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    try #require(lines.count == 62)  // 61 lines and the empty string after the last newline
    #expect(lines.first == "1.000\t2.000\t0.000")
    #expect(lines[60] == "100.000\t101.000\t2.000")
}

@Test func theFileIsInLexiconDevsLiveLaneFolder() {
    let file = PostedWindows.file(home: URL(filePath: "/home/test", directoryHint: .isDirectory))
    #expect(file.path == "/home/test/Library/Application Support/Lexicon Dev/live-lane/posted-input.tsv")
}
#endif
