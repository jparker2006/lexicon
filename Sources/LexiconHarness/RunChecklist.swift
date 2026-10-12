#if DEBUG
import Foundation
import TestHooks

/// `lexicon-harness run-checklist <file>`: runs each item of a `Checklist` its
/// `repeat` times, judges every run against its pass bars, then prints the
/// result table and the `Live checks:` comment body. A harness item runs this
/// same binary; a `sh` item runs /bin/sh, with this binary's path in
/// `$LEXICON_HARNESS` so a line can combine a hook with a read. Outputs are judged here and shown
/// only as fingerprints. The run is saved for `result`. Exits 1 if any item fails.
func runChecklist(_ arguments: [String]) async throws {
    guard arguments.count == 1 else { fail(usage, code: 64) }
    let file = URL(filePath: arguments[0])
    let checklist = try Checklist(parsing: String(contentsOf: file, encoding: .utf8))
    guard let me = Bundle.main.executablePath else { throw HarnessError("cannot find the harness's own binary") }

    var results: [ChecklistResult] = []
    for (index, item) in checklist.items.enumerated() {
        print("\(index + 1). \(item.title)")
        let clock = ContinuousClock()
        let start = clock.now
        let (tool, words) = switch item.command {
        case .harness(let words): (me, words)
        case .shell(let line): ("/bin/sh", ["-c", line])
        }
        var environment = ProcessInfo.processInfo.environment
        environment["LEXICON_HARNESS"] = me
        var outputs: [(status: Int32, output: String)] = []
        for _ in 0..<item.runs { outputs.append(try await runChild(tool, words, environment: environment)) }
        let result = ChecklistResult(item, outputs: outputs, seconds: (clock.now - start) / .seconds(1))
        print("   \(result.passes ? "Pass" : "Fail"), \(result.passed) of \(result.runs)")
        results.append(result)
    }
    try FileManager.default.createDirectory(at: harnessFolder, withIntermediateDirectories: true)
    try JSONEncoder().encode(results).write(to: lastRun, options: .atomic)

    let report = try await ChecklistReport(issue: checklist.issue ?? "?", branch: checklist.branch ?? "?",
                                           sha: checklist.sha ?? "?", app: devAppLine(), fnListeners: fnListeners,
                                           results: results)
    print("\n\(report.table)\n\n\(report.comment)")
    if results.contains(where: { !$0.passes }) { exit(1) }
}

/// The last `run-checklist`'s results, for `result`.
let lastRun = harnessFolder.appending(path: "last-run.json")

/// What scripts/harness.sh found answering fn besides Lexicon Dev, from
/// scripts/lib/fn-listeners.sh: the comment's header records it.
var fnListeners: String {
    let found = ProcessInfo.processInfo.environment["LEXICON_FN_LISTENERS"] ?? "not checked"
    return found.isEmpty ? "none" : found
}

/// "Lexicon Dev 0.1 (412, 4dfdca8), data in <root>", or why not, for the comment's header.
func devAppLine() async throws -> String {
    guard case .status(let status) = try? await DevApp.hooks.send(.status, timeout: .seconds(3)) else {
        return "Lexicon Dev not answering test hooks"
    }
    let scratch = status.dataRoot.contains(" scratch") ? "scratch data" : "its own data"
    return "Lexicon Dev \(status.version), \(scratch)"
}
#endif
