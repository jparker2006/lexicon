#if DEBUG
import Foundation
import TestHooks

/// `lexicon-harness result <issue> <branch> <sha>`: the `Live checks:` comment
/// body for the last `run-checklist` run, for posting on the issue. Refuses
/// when that run was at another sha, for another issue or on another branch.
func result(_ arguments: [String]) throws {
    guard arguments.count == 3 else { fail(usage, code: 64) }
    guard let data = try? Data(contentsOf: lastRun) else { throw HarnessError("no checklist has run to the end: run-checklist <file> first") }
    let run = try JSONDecoder().decode(ChecklistRun.self, from: data)
    print(try run.report(issue: arguments[0], branch: arguments[1], sha: arguments[2]).comment)
}
#endif
