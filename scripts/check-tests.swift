// check-tests: no test may depend on machine speed, and nothing may block a thread
// waiting.
//
//   swift scripts/check-tests.swift [path ...]    (from the package root)
//
// With no path it checks Tests, scripts and lexicon-eval's sources; each path is a
// .swift file or a folder searched for them. A step file runs it
// (scripts/checks/20-test-timing.sh), and 22-timing-harness.sh runs it over
// Sources/LexiconHarness.
//
// Why: AGENTS.md bans tests that depend on machine speed, and a ban nobody runs
// is not enforced. A sleep, a short budget or a blocking wait passes on a quiet
// Mac and fails on a busy one: in CI, or beside other builders.
//
// It fails on Task.sleep, a real clock's sleep, Thread.sleep, usleep, nanosleep,
// sleep(, asyncAfter, RunLoop's run(until:), a blocking wait() (a semaphore or a
// group), waitUntilExit, and a Duration literal under 60 s compared with
// < <= > >= or given as a timeout, deadline, within, limit or budget. It reads
// Duration literals only: a TimeInterval or Date budget, or a Duration bound to a
// name and compared on another line, is for review to catch. Comments and string
// literals are skipped, so a source string a test compiles is not a hit.
//
// A hit passes only with `// timing-ok: <why>` in a comment on its line, and only
// where machine speed cannot decide the outcome: a pure hang guard (a bound that
// turns a hang into a failure), or a wait that decides nothing on a run that
// works, however slow: a poll interval, a wedge the test itself releases, a kill
// whose moment is the test's input, a stand-in that only cancellation ends.
//
// A test that measures speed against a budget runs only in a timing run,
// `@Test(.enabled(if: timingRun))`, alone or as an && operand
// (Tests/TestSupport/TimingRun.swift). The check never runs it, so only the
// blocking rules apply in its body.
//
// Tests/TestSupport/TestClock.swift is the one file a Duration comparison
// belongs in: the fake clock compares the deadlines it is handed.
//
// Sources/LexiconHarness drives the live app, whose speed is what it checks, so
// it waits on real time by design. There only the blocking rules apply: a
// blocked thread can lose its wakeup and hang the check (#52 hung 14 minutes).
//
// `owed` lists the hits another ticket is fixing, one hit per entry, by file and
// what, so the check stays green meanwhile. Each prints as owed; a second such
// hit fails, and an entry that no longer hits fails, so whoever fixes it deletes
// it here. Never add one without its issue.
//
// Exit 0: clean. Exit 1: one line per hit. Exit 2: could not run.

import Foundation

let defaultRoots = ["Tests", "scripts", "Sources/LexiconEval", "Sources/LexiconEvalCLI"]
let clockFile = "Tests/TestSupport/TestClock.swift"
let liveApp = "Sources/LexiconHarness"

let owed: [(file: String, what: String, issue: String)] = [
    ("Tests/LexiconTests/JevClientTests.swift", "a .milliseconds(50) budget or comparison", "#149"),
    ("Tests/LexiconTests/TestHooksTests.swift", "a .milliseconds(50) budget or comparison", "#156"),
]
let fix = "wait on an explicit signal or the TestClock (\(clockFile)); run a child process with runChild "
    + "(Tests/TestSupport/ChildProcess.swift); a speed budget goes in a timing run, @Test(.enabled(if: timingRun)); "
    + "a pure hang guard may say `// timing-ok: <why>`"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("check-tests: \(message)\n".utf8))
    exit(2)
}

/// `text` split into its code and its comments, each with everything else blanked
/// to spaces and newlines kept, so line numbers still match. String literals are
/// in neither. Handles nested block comments, multi-line strings, raw strings
/// (`#"..."#`) and regex literals (`#/.../#`). An interpolation's code is read as
/// part of its string.
func split(_ text: String) -> (code: String, comments: String) {
    let chars = Array(text.unicodeScalars)
    var out = String.UnicodeScalarView(), notes = String.UnicodeScalarView()
    out.reserveCapacity(chars.count)
    notes.reserveCapacity(chars.count)
    var i = 0
    /// Blanks `c` in the code; keeps it in the comments when `comment`.
    func blank(_ c: Unicode.Scalar, comment: Bool = false) {
        out.append(c == "\n" ? "\n" : " ")
        notes.append(c == "\n" || comment ? c : " ")
    }
    func at(_ s: String, _ j: Int) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard j + scalars.count <= chars.count else { return false }
        return (0..<scalars.count).allSatisfy { chars[j + $0] == scalars[$0] }
    }
    while i < chars.count {
        if at("//", i) {
            while i < chars.count, chars[i] != "\n" { blank(chars[i], comment: true); i += 1 }
        } else if at("/*", i) {
            var depth = 0
            repeat {
                if at("/*", i) { depth += 1; blank(chars[i], comment: true); blank(chars[i + 1], comment: true); i += 2 }
                else if at("*/", i) { depth -= 1; blank(chars[i], comment: true); blank(chars[i + 1], comment: true); i += 2 }
                else { blank(chars[i], comment: true); i += 1 }
            } while depth > 0 && i < chars.count
        } else if chars[i] == "#" || chars[i] == "\"" {
            // A string or regex literal: count the leading #s, then the delimiter.
            var j = i
            while j < chars.count, chars[j] == "#" { j += 1 }
            let hashes = String(repeating: "#", count: j - i)
            let close: String
            if at("\"\"\"", j) { close = "\"\"\"" + hashes }
            else if j < chars.count, chars[j] == "\"" { close = "\"" + hashes }
            else if !hashes.isEmpty, j < chars.count, chars[j] == "/" { close = "/" + hashes }
            else { out.append(chars[i]); notes.append(" "); i += 1; continue }
            let open = j - i + (close.hasPrefix("\"\"\"") ? 3 : 1)
            for _ in 0..<open { blank(chars[i]); i += 1 }
            let escapes = hashes.isEmpty && close.hasPrefix("\"")
            while i < chars.count, !at(close, i) {
                if escapes, chars[i] == "\\", i + 1 < chars.count { blank(chars[i]); i += 1 }
                blank(chars[i]); i += 1
            }
            for _ in 0..<close.unicodeScalars.count where i < chars.count { blank(chars[i]); i += 1 }
        } else {
            out.append(chars[i]); notes.append(chars[i] == "\n" ? "\n" : " "); i += 1
        }
    }
    return (String(out), String(notes))
}

/// Simple word boundaries: by Unicode's default, `process.waitUntilExit` is one
/// word, so `\\b` would never match before `waitUntilExit`.
func regex(_ pattern: String) -> Regex<AnyRegexOutput> {
    try! Regex(pattern).wordBoundaryKind(.simple)
}

struct Rule {
    let what: String
    /// Blocks a thread, so it is banned everywhere, the live-app harness too.
    let blocks: Bool
    let pattern: Regex<AnyRegexOutput>
    /// A line this matches is not a hit: Swift's Regex has no lookbehind.
    let unless: Regex<AnyRegexOutput>?

    init(what: String, blocks: Bool = false, pattern: String, unless: String? = nil) {
        self.what = what
        self.blocks = blocks
        self.pattern = regex(pattern)
        self.unless = unless.map(regex)
    }

    func hits(_ line: Substring) -> Bool {
        line.contains(pattern) && !(unless.map { line.contains($0) } ?? false)
    }
}

// Each pattern is a string literal, so this file passes its own check.
let rules = [
    Rule(what: "Task.sleep", pattern: #"\bTask\s*\.\s*sleep\b"#),
    Rule(what: "a real clock's sleep", pattern: #"\b(?:ContinuousClock|SuspendingClock)\s*\(\s*\)\s*\.\s*sleep\b"#),
    Rule(what: "nanosleep", blocks: true, pattern: #"\bnanosleep\s*\("#),
    Rule(what: "RunLoop's run(until:)", blocks: true, pattern: #"\.\s*run\s*\(\s*(?:mode:[^)]*,\s*)?(?:until|before):"#),
    Rule(what: "Thread.sleep", blocks: true, pattern: #"\bThread\s*\.\s*sleep\b"#),
    Rule(what: "usleep", blocks: true, pattern: #"\busleep\s*\("#),
    Rule(what: "sleep(", blocks: true, pattern: #"(?:^|[^\w.])sleep\s*\("#, unless: #"\bfunc\s+sleep\s*\("#),
    Rule(what: "asyncAfter", pattern: #"\basyncAfter\b"#),
    // An awaited wait() suspends; it cannot block a thread.
    Rule(what: "a blocking wait() (semaphore or group)", blocks: true,
         pattern: #"\.\s*wait\s*\(\s*(?:\)|timeout:|wallTimeout:)"#, unless: #"\bawait\s+[\w.]+\s*\.\s*wait\s*\("#),
    Rule(what: "waitUntilExit", blocks: true, pattern: #"\bwaitUntilExit\b"#),
]

/// A Duration literal: `.seconds(2)`, `Duration.milliseconds(1_500)`.
let durationLiteral = try! Regex<(Substring, Substring, Substring)>(
    #"(?:\bDuration)?\.(nanoseconds|microseconds|milliseconds|seconds)\s*\(\s*([0-9][0-9_]*(?:\.[0-9]+)?)\s*\)"#
).wordBoundaryKind(.simple)
/// A comparison: Swift requires the same spacing on both sides of a binary
/// operator, so a spaced `<` is a comparison and `Clock<Duration>` is not.
let comparison = regex(" (?:<|<=|>|>=) ")
/// The argument label or name a budget is given under, right before the literal,
/// typed or not: `timeout: .seconds(1)`, `let limit: Duration = .seconds(1)`.
let budgetLabel = regex(#"(?i)(?:timeout|deadline|within|limit|budget)\w*\s*(?::\s*Duration\??\s*)?[:=]\s*(?:Duration)?$"#)

func seconds(_ unit: Substring, _ value: Substring) -> Double {
    let number = Double(value.replacing("_", with: "")) ?? 0
    switch unit {
    case "nanoseconds": return number / 1e9
    case "microseconds": return number / 1e6
    case "milliseconds": return number / 1e3
    default: return number
    }
}

/// What on this line of code depends on machine speed, if anything; with
/// `blockingOnly`, only what blocks a thread.
func hits(in line: Substring, blockingOnly: Bool) -> [String] {
    var found = rules.filter { (!blockingOnly || $0.blocks) && $0.hits(line) }.map(\.what)
    guard !blockingOnly else { return found }
    let compares = line.contains(comparison)
    for match in line.matches(of: durationLiteral) where seconds(match.1, match.2) < 60 {
        let before = line[line.startIndex..<match.range.lowerBound]
        if compares || before.contains(budgetLabel) {
            found.append("a \(match.0.trimmingCharacters(in: .whitespaces)) budget or comparison")
            break
        }
    }
    return found
}

let timingAttribute = regex(#"@Test\s*\(.*\.enabled\s*\(\s*if:\s*(?:\w+\s*&&\s*)*timingRun(?:\s*&&\s*\w+)*\s*\)"#)
let timingOK = regex(#"//\s*timing-ok:\s*\S"#)

func swiftFiles(under root: String) -> [String] {
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isFolder) else { fail("no such path: \(root)") }
    guard isFolder.boolValue else { return [root] }
    guard let walker = FileManager.default.enumerator(atPath: root) else { fail("cannot read \(root)") }
    return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") && !$0.contains(".build/") }
        .map { root.hasSuffix("/") ? root + $0 : root + "/" + $0 }.sorted()
}

/// `file` relative to the package root, however it was named: `./Tests/...` or absolute.
func relative(_ file: String) -> String {
    let root = FileManager.default.currentDirectoryPath + "/"
    let path = URL(filePath: file).standardizedFileURL.path(percentEncoded: false)
    return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
}

let roots = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : defaultRoots
var violations: [String] = []
var owing: [String] = []
var unpaid = Set(owed.indices)
var files = 0
for file in roots.flatMap(swiftFiles(under:)) {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { fail("cannot read \(file)") }
    files += 1
    let path = relative(file)
    let parts = split(text.replacingOccurrences(of: "\r\n", with: "\n"))
    let comments = parts.comments.split(separator: "\n", omittingEmptySubsequences: false)
    // A timing-run test's body, from its attribute to the brace that closes it.
    var timing = (pending: false, depth: 0, inside: false)
    for (index, line) in parts.code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var inTimingRun = false
        if line.contains(timingAttribute) { timing.pending = true }
        if timing.pending || timing.inside {
            inTimingRun = true
            for character in line where character == "{" || character == "}" {
                timing.depth += character == "{" ? 1 : -1
                if character == "{", timing.pending { timing = (false, timing.depth, true) }
            }
            if timing.inside, timing.depth == 0 { timing.inside = false }
        }
        guard !comments[index].contains(timingOK) else { continue }
        for what in hits(in: line, blockingOnly: inTimingRun || path.hasPrefix(liveApp + "/"))
        where !(path == clockFile && what.hasSuffix("budget or comparison")) {
            let at = "\(path):\(index + 1): \(what)"
            if let entry = unpaid.first(where: { owed[$0].file == path && owed[$0].what == what }) {
                unpaid.remove(entry)
                owing.append("\(at): owed, \(owed[entry].issue) is fixing it")
            } else {
                violations.append("\(at): tests must not depend on machine speed; \(fix)")
            }
        }
    }
}

// An entry is paid only where its file was checked; another run's roots may not hold it.
for entry in unpaid.sorted() where roots == defaultRoots {
    violations.append("\(owed[entry].file): no longer has \(owed[entry].what) (\(owed[entry].issue)); delete its owed entry")
}
owing.forEach { print($0) }
if violations.isEmpty {
    print("check-tests: OK (\(files) files)")
    exit(0)
}
violations.forEach { print($0) }
print("check-tests: \(violations.count) hit(s)")
exit(1)
