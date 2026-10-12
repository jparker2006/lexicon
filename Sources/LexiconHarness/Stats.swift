#if DEBUG
import Foundation
import TestHooks

/// `lexicon-harness stats <file>`: n, p50, p95 and max of a saved sample, by
/// nearest rank as scripts/lag-report.sh reads them. Takes the first number on
/// each line, so a file of numbers and a file of log lines ("lag 131 ms") both work.
func stats(_ arguments: [String]) throws {
    guard arguments.count == 1 else { fail(usage, code: 64) }
    let text = try String(contentsOf: URL(filePath: arguments[0]), encoding: .utf8)
    print(Sample(lines: text).summary)
}
#endif
