#if DEBUG
import Foundation
import TestHooks

/// `lexicon-harness result <issue> <branch> <sha>`: the `Live checks:` comment
/// body for the last `run-checklist` run, for posting on the issue.
func result(_ arguments: [String]) async throws {
    guard arguments.count == 3 else { fail(usage, code: 64) }
    guard let data = try? Data(contentsOf: lastRun) else { throw HarnessError("no checklist has run yet: run-checklist <file> first") }
    let results = try JSONDecoder().decode([ChecklistResult].self, from: data)
    let report = ChecklistReport(issue: arguments[0], branch: arguments[1], sha: arguments[2], app: try await devAppLine(),
                                 fnListeners: fnListeners, results: results)
    print(report.comment)
}
#endif
