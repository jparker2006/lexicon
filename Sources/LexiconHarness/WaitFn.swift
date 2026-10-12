#if DEBUG
import Foundation
import TestHooks

/// `lexicon-harness wait-fn [--count <n>] [--timeout <seconds>]`: prints each
/// Dictation's outcome as Lexicon Dev logs it (one line per Dictation, from
/// `Conductor.land`), until `count` of them have landed. For real fn presses:
/// the session reads the result here instead of asking Jake "done". The log
/// line holds no text, and a failure's reason is private, so neither is printed.
func waitFn(_ arguments: [String]) async throws {
    var count = 1, timeout = 120.0
    var words = arguments[...]
    while let flag = words.popFirst() {
        guard let value = words.popFirst() else { fail(usage, code: 64) }
        switch flag {
        case "--count": guard let n = Int(value), n > 0 else { fail(usage, code: 64) }; count = n
        case "--timeout": guard let s = Double(value), s > 0 else { fail(usage, code: 64) }; timeout = s
        default: fail(usage, code: 64)
        }
    }

    // scripts/harness.sh refuses first; this covers a wait-fn inside run-checklist.
    if let others = ProcessInfo.processInfo.environment["LEXICON_FN_LISTENERS"], !others.isEmpty {
        throw HarnessError("another app answers fn (\(others)), so real fn results would be wrong. Quit it from its menu bar, then rerun.")
    }
    let stream = Process()
    stream.executableURL = URL(filePath: "/usr/bin/log")
    stream.arguments = ["stream", "--style", "ndjson", "--predicate",
                        "subsystem == \"Lexicon\" && category == \"dictation\" && processImagePath CONTAINS \"/Lexicon Dev.app/\""]
    let pipe = Pipe()
    stream.standardOutput = pipe
    try stream.run()
    defer { stream.terminate() }
    // To stderr, so `wait-fn > file` holds only outcomes for `stats`.
    FileHandle.standardError.write(Data("waiting for \(count) Dictation\(count == 1 ? "" : "s") in Lexicon Dev, up to \(Int(timeout)) s\n".utf8))

    // The time limit ends the stream (by the pid this command started), which ends the lines below.
    let pid = stream.processIdentifier
    let limit = Task {
        try await Task.sleep(for: .seconds(timeout))  // timing-ok: the command's own time limit
        kill(pid, SIGTERM)
    }
    defer { limit.cancel() }
    var seen = 0
    for try await line in pipe.fileHandleForReading.bytes.lines {
        guard let outcome = DictationOutcome(ndjson: line) else { continue }
        print(outcome)
        seen += 1
        if seen == count { break }
    }
    guard seen == count else { throw HarnessError("no \(count == 1 ? "Dictation" : "\(count) Dictations") landed within \(Int(timeout)) s") }
}

/// One `Dictation <id> <status>: ...` line, numbers and names only.
struct DictationOutcome: CustomStringConvertible {
    let id: String
    let status: String
    let detail: String

    init?(ndjson line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = event["eventMessage"] as? String,
              let match = message.firstMatch(of: /^Dictation (\S+) (has no mic|\w+):?\s*(.*)$/) else { return nil }
        id = String(match.1.prefix(8))
        status = match.2 == "has no mic" ? "noMic" : String(match.2)
        // Lag, engine and speech time are public; a failure's reason is private and reads "<private>".
        detail = match.3.contains("<private>") || status == "noMic" ? "" : String(match.3)
    }

    var description: String { "\(status)  \(id)  \(detail)" }
}
#endif
