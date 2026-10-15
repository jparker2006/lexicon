import Foundation
import Testing

private struct BenchReport {
    let status: Int32
    let output: String
}

private func settingsBenchReport(budget: String, a: [Int], b: [Int]) async throws -> BenchReport {
    let home = try scratchDirectory()
    let fakeBin = home.appending(path: "fake-bin")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)

    let fakePS = fakeBin.appending(path: "ps")
    try "#!/bin/sh\nexit 0\n".write(to: fakePS, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePS.path)

    let background = home.appending(path: "Library/Application Support/Lexicon Dev/live-lane/bench-background")
    try fileManager.createDirectory(at: background.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "0.25\n".write(to: background, atomically: true, encoding: .utf8)

    let aFile = home.appending(path: "A.txt")
    let bFile = home.appending(path: "B.txt")
    let loadFile = home.appending(path: "load.txt")
    try a.map { String($0) }.joined(separator: "\n").appending("\n")
        .write(to: aFile, atomically: true, encoding: .utf8)
    try b.map { String($0) }.joined(separator: "\n").appending("\n")
        .write(to: bFile, atomically: true, encoding: .utf8)
    try "# synthetic load\n1 0.25\n2 0.25\n3 0.25\n".write(to: loadFile, atomically: true, encoding: .utf8)

    let repository = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let benchScript = repository.appending(path: "scripts/bench.sh")
    let isolatedPath = "\(fakeBin.path):/usr/bin:/bin"
    let child = try await runChild(URL(filePath: "/usr/bin/env"), [
        "HOME=\(home.path)",
        "PATH=\(isolatedPath)",
        "/bin/sh",
        benchScript.path,
        "report",
        budget,
        aFile.path,
        bFile.path,
        loadFile.path
    ])
    return BenchReport(status: child.status, output: child.output)
}

private func containsNoComparativeResult(_ output: String) -> Bool {
    !output.contains("A - B")
        && !output.localizedCaseInsensitiveContains("delta")
        && !output.localizedCaseInsensitiveContains("ratio")
        && !output.localizedCaseInsensitiveContains("speedup")
}

@Test(.timeLimit(.minutes(1)))
func settingsOpenReportLabelsSettingsAndHistoryWithoutComparingThem() async throws {
    let report = try await settingsBenchReport(
        budget: "settings-open",
        a: [90, 10, 20, 30, 40, 50],
        b: [900, 910, 920, 930, 940, 950]
    )

    #expect(report.status == 0)
    #expect(report.output.contains("Settings (Keys only)"))
    #expect(report.output.contains("main History control"))
    #expect(report.output.localizedCaseInsensitiveContains("first"))
    #expect(report.output.contains("PASS"))
    #expect(containsNoComparativeResult(report.output))
}

@Test(.timeLimit(.minutes(1)))
func settingsOpenReportChecksTheFirstShowSeparately() async throws {
    let report = try await settingsBenchReport(
        budget: "settings-open",
        a: [101] + Array(repeating: 0, count: 20),
        b: [900, 910, 920, 930, 940, 950]
    )

    #expect(report.status != 0)
    #expect(report.output.contains("Settings (Keys only)"))
    #expect(report.output.localizedCaseInsensitiveContains("first"))
    #expect(report.output.contains("101"))
    #expect(report.output.contains("FAIL"))
    #expect(containsNoComparativeResult(report.output))
}

@Test(.timeLimit(.minutes(1)))
func settingsOpenReportGatesOnSettingsP95EvenWhenHistoryIsFaster() async throws {
    let report = try await settingsBenchReport(
        budget: "settings-open",
        a: [20, 110, 120, 130, 140, 150],
        b: [10, 15, 20, 25, 30, 35]
    )

    #expect(report.status != 0)
    #expect(report.output.contains("Settings (Keys only)"))
    #expect(report.output.contains("p95"))
    #expect(report.output.contains("FAIL"))
    #expect(containsNoComparativeResult(report.output))
}

@Test(.timeLimit(.minutes(1)))
func historyAndLaunchReportsKeepTheirExistingLabelsAndComparison() async throws {
    for (budget, samples) in [("history-open", [60, 65, 70, 75, 80]), ("launch", [60, 65, 70, 75, 80])] {
        let report = try await settingsBenchReport(budget: budget, a: samples, b: samples)

        #expect(report.status == 0)
        #expect(report.output.contains("A (branch)"))
        #expect(report.output.contains("B (main)"))
        #expect(report.output.contains("A - B"))
        #expect(!report.output.contains("Settings (Keys only)"))
        #expect(!report.output.contains("main History control"))
    }
}
