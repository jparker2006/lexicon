#if DEBUG
import CryptoKit
import Foundation

// The pure half of the harness's `run-checklist`, `result`, `stats` and
// `fixture`: parsing, pass bars, the result table and the numbers. Here rather
// than in the harness so tests can reach it; the harness runs the commands.

/// A declarative Live checks list: what to run, how often, and what passes.
///
///     # comments and blank lines are skipped
///     issue: 54
///     branch: claude/issue-54
///
/// The sha a run is reported at is the one Lexicon Dev was built from. A
/// `sha:` line, for a request pinned to one build, makes a run on any other
/// build refuse.
///     item: paste-check lands the text and puts the clipboard back
///     run: paste-check
///     repeat: 10
///     pass: exit 0
///
/// `run` is a harness command line (quotes group words), or `sh <command>` for
/// a shell line. `pass` lines all must hold on every run: `exit <code>`,
/// `has <text>` or `lacks <text>` (the output contains it, or doesn't). A run
/// must also exit 0 unless an `exit` line names another code, so a command
/// that failed never passes on its output. No `repeat` means once.
public struct Checklist: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let title: String
        public let command: Command
        public let runs: Int
        public let bars: [PassBar]
    }

    public enum Command: Sendable, Equatable {
        case harness([String])
        case shell(String)
    }

    public enum PassBar: Sendable, Equatable {
        case exit(Int32)
        case has(String)
        case lacks(String)

        var isExit: Bool { if case .exit = self { true } else { false } }

        public func holds(status: Int32, output: String) -> Bool {
            switch self {
            case .exit(let code): status == code
            case .has(let text): output.contains(text)
            case .lacks(let text): !output.contains(text)
            }
        }
    }

    public let issue: String?
    public let branch: String?
    public let sha: String?
    public let items: [Item]

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let reason: String
        public var description: String { "line \(line): \(reason)" }
    }

    public init(parsing text: String) throws(ParseError) {
        var header: [String: String] = [:]
        var items: [Item] = []
        var open: (line: Int, title: String, command: Command?, runs: Int, bars: [PassBar])?

        func close() throws(ParseError) {
            guard let block = open else { return }
            guard let command = block.command else { throw ParseError(line: block.line, reason: "item has no run line") }
            items.append(Item(title: block.title, command: command, runs: block.runs,
                              bars: block.bars.contains(where: \.isExit) ? block.bars : [.exit(0)] + block.bars))
            open = nil
        }

        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw ParseError(line: number, reason: "expected key: value")
            }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { throw ParseError(line: number, reason: "\(key) has no value") }
            switch key {
            case "issue", "branch", "sha":
                guard open == nil, items.isEmpty else {
                    throw ParseError(line: number, reason: "\(key) belongs above the first item")
                }
                header[key] = value
            case "item":
                try close()
                open = (number, value, nil, 1, [])
            case "run", "repeat", "pass":
                guard open != nil else { throw ParseError(line: number, reason: "\(key) outside an item") }
                switch key {
                case "run":
                    if value.hasPrefix("sh ") {
                        open?.command = .shell(String(value.dropFirst(3)))
                    } else {
                        guard let words = Self.words(value) else {
                            throw ParseError(line: number, reason: "unclosed quote")
                        }
                        open?.command = .harness(words)
                    }
                case "repeat":
                    guard let runs = Int(value), runs > 0 else {
                        throw ParseError(line: number, reason: "repeat takes a count above 0")
                    }
                    open?.runs = runs
                default:
                    open?.bars.append(try Self.bar(value, line: number))
                }
            default:
                throw ParseError(line: number, reason: "unknown key \(key)")
            }
        }
        try close()
        guard !items.isEmpty else { throw ParseError(line: 0, reason: "no items") }
        (issue, branch, sha) = (header["issue"], header["branch"], header["sha"])
        self.items = items
    }

    static func bar(_ value: String, line: Int) throws(ParseError) -> PassBar {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("exit", 2):
            guard let code = Int32(parts[1]) else { throw ParseError(line: line, reason: "exit takes a code") }
            return .exit(code)
        case ("has", 2): return .has(parts[1])
        case ("lacks", 2): return .lacks(parts[1])
        default: throw ParseError(line: line, reason: "pass is exit <code>, has <text> or lacks <text>")
        }
    }

    /// Words split on spaces, with '…' or "…" grouping. nil on an unclosed quote.
    static func words(_ line: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character == " " {
                if inWord { words.append(word) }
                (word, inWord) = ("", false)
            } else {
                word.append(character)
                inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { words.append(word) }
        return words
    }
}

/// One item's runs, as `run-checklist` saw them.
public struct ChecklistResult: Codable, Sendable, Equatable {
    public let title: String
    public let runs: Int
    public let passed: Int
    public let seconds: Double
    /// The last run's output, as a fingerprint.
    public let output: String
    /// The first failing run's bar and its last output line: quoted text
    /// fingerprinted for a harness item, the whole line for a shell one.
    public let failure: String?

    public init(title: String, runs: Int, passed: Int, seconds: Double, output: String, failure: String?) {
        (self.title, self.runs, self.passed, self.seconds, self.output, self.failure) =
            (title, runs, passed, seconds, output, failure)
    }

    /// Judges `outputs` (status and output of each run) against `item`.
    public init(_ item: Checklist.Item, outputs: [(status: Int32, output: String)], seconds: Double) {
        var failure: String?
        var passed = 0
        for (run, result) in outputs.enumerated() {
            if let bar = item.bars.first(where: { !$0.holds(status: result.status, output: result.output) }) {
                let last = result.output.split(separator: "\n").last.map(String.init) ?? ""
                // The harness quotes any text it prints; a shell line can print anything.
                let shown = if case .shell = item.command { Fingerprint(last).description } else { Fingerprint.quotes(in: last) }
                failure = failure ?? "run \(run + 1): \(Self.describe(bar)), exit \(result.status): \(shown)"
            } else {
                passed += 1
            }
        }
        self.init(title: item.title, runs: outputs.count, passed: passed, seconds: seconds,
                  output: Fingerprint(outputs.last?.output ?? "").description, failure: failure)
    }

    public var passes: Bool { passed == runs }

    static func describe(_ bar: Checklist.PassBar) -> String {
        switch bar {
        case .exit(let code): "wanted exit \(code)"
        case .has(let text): "wanted has \(text)"
        case .lacks(let text): "wanted lacks \(text)"
        }
    }
}

/// One `run-checklist` run, saved for `result`: the sha it ran at and how it
/// went. Keyed to that sha, so a later run's comment can never carry its passes.
public struct ChecklistRun: Codable, Sendable, Equatable {
    public let issue: String?
    public let branch: String?
    /// The commit Lexicon Dev was built from, else the checklist's `sha`.
    public let sha: String?
    public let app: String
    /// Other apps answering fn while it ran: "none", or their names.
    public let fnListeners: String
    public let results: [ChecklistResult]

    public init(issue: String?, branch: String?, sha: String?, app: String, fnListeners: String,
                results: [ChecklistResult]) {
        (self.issue, self.branch, self.sha, self.app, self.fnListeners, self.results) =
            (issue, branch, sha, app, fnListeners, results)
    }

    public struct Mismatch: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// This run as the comment for `issue`, `branch` and `sha`, or why it is not theirs.
    public func report(issue: String, branch: String, sha: String) throws(Mismatch) -> ChecklistReport {
        guard let ran = self.sha else { throw Mismatch(description: "the last run has no sha: name one in the checklist") }
        guard Self.same(ran, sha) else { throw Mismatch(description: "the last run was at \(ran.prefix(7)), not \(sha.prefix(7))") }
        let bare = { (issue: String) in issue.hasPrefix("#") ? String(issue.dropFirst()) : issue }
        if let ranIssue = self.issue, bare(ranIssue) != bare(issue) {
            throw Mismatch(description: "the last run was for #\(bare(ranIssue)), not #\(bare(issue))")
        }
        if let ranBranch = self.branch, ranBranch != branch {
            throw Mismatch(description: "the last run was on \(ranBranch), not \(branch)")
        }
        return ChecklistReport(issue: issue, branch: branch, sha: ran, app: app, fnListeners: fnListeners, results: results)
    }

    /// Two abbreviations of one commit: the shorter, at least 7 characters, starts the longer.
    public static func same(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a.lowercased(), b.lowercased()) : (b.lowercased(), a.lowercased())
        return short.count >= 7 && long.hasPrefix(short)
    }
}

/// The run as a `Live checks:` comment: header, table and verdict. No output
/// text, only fingerprints, so nothing a field held reaches GitHub.
public struct ChecklistReport: Sendable, Equatable {
    public let issue: String
    /// nil when the checklist names none: the header then gives the sha alone.
    public let branch: String?
    public let sha: String
    public let app: String
    public let fnListeners: String
    public let results: [ChecklistResult]

    public init(issue: String, branch: String?, sha: String, app: String, fnListeners: String,
                results: [ChecklistResult]) {
        (self.issue, self.branch, self.sha, self.app, self.fnListeners, self.results) =
            (issue, branch, sha, app, fnListeners, results)
    }

    public var table: String {
        var lines = ["| # | Item | Result | Time | Output |", "|---|---|---|---|---|"]
        for (index, result) in results.enumerated() {
            let verdict = "\(result.passes ? "Pass" : "Fail"), \(result.passed) of \(result.runs)"
            let note = result.failure ?? result.output
            lines.append("| \(index + 1) | \(cell(result.title)) | \(verdict) | \(String(format: "%.1f s", result.seconds)) | \(cell(note)) |")
        }
        return lines.joined(separator: "\n")
    }

    public var comment: String {
        let passed = results.filter(\.passes).count
        let issue = issue.hasPrefix("#") ? issue : "#\(issue)"
        return """
            Live checks: \(issue)\(branch.map { ", \($0)" } ?? "") @ \(sha.prefix(7))

            \(app). fn listeners: \(fnListeners).

            \(table)

            \(passed == results.count ? "Pass" : "Fail"): \(passed) of \(results.count) items.
            """
    }

    private func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|") }
}

/// Text as its length and a short hash: enough to tell two outputs apart, or
/// match one to its fixture, without printing what was dictated or typed.
public struct Fingerprint: CustomStringConvertible, Sendable, Equatable {
    public let characters: Int
    public let hash: String

    public init(_ text: String) {
        characters = text.count
        hash = SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { "\(characters) chars #\(hash)" }

    /// `line` with every "quoted" stretch replaced by its fingerprint: error
    /// lines quote what a field held.
    public static func quotes(in line: String) -> String {
        line.replacing(/"(?:[^"\\]|\\.)*"/) { match in "<\(Fingerprint(String(match.output.dropFirst().dropLast())))>" }
    }
}

/// Nearest-rank percentiles, the reading scripts/lag-report.sh uses: sorted,
/// the value at rank ceil(n × p / 100).
public struct Sample: Sendable, Equatable {
    public let sorted: [Double]

    public init(_ values: [Double]) { sorted = values.sorted() }

    /// One number per line: the first given in ms ("lag 131 ms", as in a log
    /// or `wait-fn` line), or a line that is only a number. Any other line is
    /// skipped, so an id's digits never count.
    public init(lines text: String) {
        self.init(text.split(separator: "\n").compactMap { line in
            let number = line.firstMatch(of: /(\d+(?:\.\d+)?) ms\b/).map(\.1)
                ?? line.wholeMatch(of: /\s*(-?\d+(?:\.\d+)?)\s*/).map(\.1)
            return number.flatMap { Double($0) }
        })
    }

    public func percentile(_ p: Int) -> Double? {
        guard !sorted.isEmpty else { return nil }
        return sorted[(sorted.count * p + 99) / 100 - 1]
    }

    public var summary: String {
        guard let p50 = percentile(50), let p95 = percentile(95), let max = sorted.last else { return "n 0" }
        let number = { (value: Double) in value == value.rounded() ? String(Int(value)) : String(value) }
        return "n \(sorted.count), p50 \(number(p50)), p95 \(number(p95)), max \(number(max))"
    }
}
#endif
