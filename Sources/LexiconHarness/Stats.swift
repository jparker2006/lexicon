#if DEBUG
import Foundation
import TestHooks

/// `lexicon-harness stats <file>`: n, p50, p95 and max of a saved sample, by
/// nearest rank as scripts/lag-report.sh reads them. Takes a line's first
/// number in ms, or a line that is only a number, so a file of numbers, log
/// lines and `wait-fn` output ("lag 131 ms") all work.
func stats(_ arguments: [String]) throws {
    guard arguments.count == 1 else { fail(usage, code: 64) }
    let text = try String(contentsOf: URL(filePath: arguments[0]), encoding: .utf8)
    print(Sample(lines: text).summary)
}
#endif
