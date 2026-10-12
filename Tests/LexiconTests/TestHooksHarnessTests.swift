#if DEBUG
import Foundation
import Testing
@testable import TestHooks

// The pure half of the harness's run-checklist, result, stats and fixture
// commands (#156): the checklist format, pass bars, the result table and
// comment, fingerprints in place of text, and nearest-rank percentiles.

/// #54's hands-off paste items, as Live checks ran them on 2026-10-11.
private let pasteChecklist = """
    # #54 hands-off paste items
    issue: 54
    branch: main
    sha: d347832

    item: paste-check lands the text and puts the clipboard back
    run: paste-check
    repeat: 10

    item: the fn tap ignores Lexicon's own Cmd-V
    run: sh /usr/bin/log show --last 5m --style compact --predicate 'subsystem == "Lexicon" && category == "fn"'
    pass: exit 0
    pass: lacks fn gesture
    """

@Test func aChecklistReadsItsHeaderItemsRunsAndBars() throws {
    let checklist = try Checklist(parsing: pasteChecklist)
    #expect(checklist.issue == "54")
    #expect(checklist.sha == "d347832")
    #expect(checklist.items.map(\.runs) == [10, 1])
    #expect(checklist.items[0].command == .harness(["paste-check"]))
    #expect(checklist.items[0].bars == [.exit(0)])
    #expect(checklist.items[1].bars == [.exit(0), .lacks("fn gesture")])
    guard case .shell(let line) = checklist.items[1].command else { Issue.record("not a shell item"); return }
    #expect(line.hasPrefix("/usr/bin/log show"))
}

@Test func harnessCommandLinesKeepQuotedWordsTogether() throws {
    let checklist = try Checklist(parsing: "item: insert\nrun: hook insert --delay 0.05 \" second.\"")
    #expect(checklist.items[0].command == .harness(["hook", "insert", "--delay", "0.05", " second."]))
}

@Test func aBadChecklistNamesItsLine() {
    #expect(throws: Checklist.ParseError(line: 1, reason: "item has no run line")) {
        try Checklist(parsing: "item: no command\nrepeat: 2")
    }
    #expect(throws: Checklist.ParseError(line: 3, reason: "pass is exit <code>, has <text> or lacks <text>")) {
        try Checklist(parsing: "item: x\nrun: check\npass: equals 3")
    }
    #expect(throws: Checklist.ParseError(line: 3, reason: "issue belongs above the first item")) {
        try Checklist(parsing: "item: x\nrun: check\nissue: 54")
    }
}

@Test func theTableAndCommentShowRunsAndFingerprintsNeverText() throws {
    let fixture = "refactor the useAuth hook"
    let checklist = try Checklist(parsing: pasteChecklist)
    let pastes = (0..<10).map { run in
        run == 6 ? (status: Int32(1), output: "FAIL  the target field reads \"\(fixture)\", not \"\"")
            : (status: Int32(0), output: "ok    target field reads the pasted text \(fixture)")
    }
    let results = [ChecklistResult(checklist.items[0], outputs: pastes, seconds: 31.2),
                   ChecklistResult(checklist.items[1], outputs: [(0, "Timestamp  Ty Process[PID:TID]\n")], seconds: 0.8)]
    let report = ChecklistReport(issue: "54", branch: "main", sha: "d3478321abc", app: "Lexicon Dev 0.1 (412, d347832)",
                                 fnListeners: "none", results: results)

    #expect(results.map(\.passes) == [false, true])
    #expect(report.table.contains("| 1 | paste-check lands the text and puts the clipboard back | Fail, 9 of 10 | 31.2 s |"))
    #expect(report.table.contains("run 7: wanted exit 0, exit 1: FAIL  the target field reads <\(Fingerprint(fixture))>"))
    #expect(report.table.contains("| 2 | the fn tap ignores Lexicon's own Cmd-V | Pass, 1 of 1 | 0.8 s |"))
    #expect(report.comment.hasPrefix("Live checks: main @ d347832\n\n#54. Lexicon Dev 0.1 (412, d347832). fn listeners: none."))
    #expect(report.comment.hasSuffix("Fail: 1 of 2 items."))
    let unnamed = ChecklistReport(issue: "54", branch: nil, sha: "d3478321abc", app: "Lexicon Dev", fnListeners: "none",
                                  results: results)
    #expect(unnamed.comment.hasPrefix("Live checks: <no branch named> @ d347832\n"))
    #expect(!report.comment.contains(fixture))
}

@Test func aFailingShellItemShowsItsLastLineOnlyAsAFingerprint() throws {
    let item = try Checklist(parsing: "item: field\nrun: sh echo the field reads refactor the hook").items[0]
    let result = ChecklistResult(item, outputs: [(1, "the field reads refactor the hook\n")], seconds: 0.1)
    #expect(result.failure == "run 1: wanted exit 0, exit 1: \(Fingerprint("the field reads refactor the hook"))")
}

@Test func aCommandThatFailsNeverPassesOnItsOutput() throws {
    let items = try Checklist(parsing: """
        item: has
        run: sh echo ok; exit 1
        pass: has ok

        item: lacks
        run: sh exit 2
        pass: lacks FAIL

        item: an exit code named
        run: sh exit 3
        pass: exit 3
        """).items
    #expect(items.map(\.bars) == [[.exit(0), .has("ok")], [.exit(0), .lacks("FAIL")], [.exit(3)]])
    #expect(!ChecklistResult(items[0], outputs: [(1, "ok\n")], seconds: 0).passes)
    #expect(!ChecklistResult(items[1], outputs: [(2, "")], seconds: 0).passes)
    #expect(ChecklistResult(items[2], outputs: [(3, "")], seconds: 0).passes)
}

/// `result`'s comment answers its request in the Live checks queue: scripts/live-lane.sh
/// counts a request `Live checks request: <branch> @ <sha7>` answered by a comment
/// that starts `Live checks: ` plus the same `<branch> @ <sha7>`.
@Test func aResultAnswersItsRequestInTheLiveChecksQueue() throws {
    let request = "Live checks request: claude/issue-54 @ d347832"
    let head = String(request.dropFirst("Live checks request: ".count))
    let item = try Checklist(parsing: "item: x\nrun: check").items[0]
    let run = ChecklistRun(issue: "54", branch: "claude/issue-54", sha: "d3478321abcdef", app: "Lexicon Dev",
                           fnListeners: "none", results: [ChecklistResult(item, outputs: [(0, "")], seconds: 1)])
    let comment = try run.report(issue: "54", branch: "claude/issue-54", sha: "d347832").comment
    #expect(comment.hasPrefix("Live checks: " + head))
}

/// A run saved at one sha can only be posted as that sha's result.
@Test func aSavedRunIsPostedOnlyForTheShaItRanAt() throws {
    let item = try Checklist(parsing: "item: x\nrun: check").items[0]
    let run = ChecklistRun(issue: "54", branch: "main", sha: "d3478321abc", app: "Lexicon Dev 0.1 (1, d347832)",
                           fnListeners: "none", results: [ChecklistResult(item, outputs: [(0, "")], seconds: 1)])

    #expect(try run.report(issue: "#54", branch: "main", sha: "d347832").comment.hasPrefix("Live checks: main @ d347832"))
    #expect(throws: ChecklistRun.Mismatch(description: "the last run was at d347832, not 10d35db")) {
        try run.report(issue: "54", branch: "main", sha: "10d35db")
    }
    #expect(throws: ChecklistRun.Mismatch(description: "the last run was for #54, not #156")) {
        try run.report(issue: "156", branch: "main", sha: "d347832")
    }
    #expect(throws: ChecklistRun.Mismatch(description: "the last run was on main, not claude/issue-156")) {
        try run.report(issue: "54", branch: "claude/issue-156", sha: "d347832")
    }
    let unnamed = ChecklistRun(issue: nil, branch: nil, sha: nil, app: "", fnListeners: "none", results: run.results)
    #expect(throws: ChecklistRun.Mismatch(description: "the last run has no sha: name one in the checklist")) {
        try unnamed.report(issue: "54", branch: "main", sha: "d347832")
    }
}

@Test func theStatusNamesTheCommitTheAppWasBuiltFrom() {
    #expect(status(version: "0.1 (412, 4dfdca8)").commit == "4dfdca8")
    #expect(status(version: "0.1 (412, ?)").commit == nil)
}

private func status(version: String) -> TestHookStatus {
    TestHookStatus(bundleID: "dev.jparker.lexicon.dev", version: version, pid: 1, accessibility: true,
                   microphone: "granted", privacy: .standard, alwaysPrivateApps: [], dataRoot: "/tmp")
}

@Test func aFingerprintIsTheLengthAndAHashNotTheText() {
    let text = "Ship it to staging"
    #expect(Fingerprint(text).description.hasPrefix("18 chars #"))
    #expect(Fingerprint(text) == Fingerprint(text))
    #expect(Fingerprint(text) != Fingerprint("Ship it to prod"))
    #expect(!Fingerprint(text).description.contains("Ship"))
}

/// #57's warm relaunch timings (comment of 2026-10-11 23:29Z): three runs each,
/// with the medians posted then. Nearest rank reproduces them; on an even or
/// hand-picked sample it can differ from a posted median, as on #53.
@Test func statsGivesNearestRankPercentilesAsLagReportDoes() {
    #expect(Sample([54, 46, 41]).summary == "n 3, p50 46, p95 54, max 54")    // main fn working, posted 46
    #expect(Sample([187, 183, 192]).summary == "n 3, p50 187, p95 192, max 192")  // branch status item, posted 187
    // #53's fn-up delivery times (µs), 19 values: nearest rank gives 259 (#53 posted 245).
    let up: [Double] = [528, 545, 585, 340, 289, 259, 238, 99, 113, 351, 221, 292, 221, 561, 477, 112, 149, 245, 108]
    #expect(Sample(up).percentile(50) == 259)
    #expect(Sample(up).percentile(95) == 585)
}

@Test func statsReadsTheMillisecondsOnALogOrWaitFnLine() {
    let lines = """
        inserted  4AB12CD3  lag 131 ms, engine local:parakeetUnified, speech 80 ms
        inserted  9F0E77A1  lag 588 ms, engine local:parakeetUnified, speech 95 ms
        212
        failed  9F0E77A1  
        """
    #expect(Sample(lines: lines).sorted == [131, 212, 588])
}
#endif
