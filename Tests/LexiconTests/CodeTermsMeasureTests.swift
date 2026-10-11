import Darwin
import Foundation
import Testing
import LexiconDomain
@testable import WordStore

// The measurement behind #72's budgets: a full scan of the real `~/code` under
// 1 s adding under 5 MB, and a touched file making its repo current within a
// second. It reads the Mac's own folders, so it runs only when asked:
//
//   LEXICON_MEASURE_CODE=1 swift test -c release --filter CodeTermsMeasure
//
// It prints counts, times and memory only, never a name: repo and dependency
// names may be private and this repo is public.

private let measuring = ProcessInfo.processInfo.environment["LEXICON_MEASURE_CODE"] == "1"

/// This process's footprint, the number Activity Monitor shows as Memory.
private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

@Test(.enabled(if: measuring)) func codeTermsMeasureTheRealCodeFolder() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let code = home.appending(path: "code")
    let clock = ContinuousClock()
    // Warm the file cache and the word list once, as a launch after login would have.
    _ = CodeScan.scan(code: code, home: home)

    var times: [Double] = []
    var growth: [Int] = []
    var index = CodeIndex()
    for _ in 0..<5 {
        let before = footprint()
        let start = clock.now
        index = CodeScan.scan(code: code, home: home)
        times.append(milliseconds(clock.now - start))
        growth.append(footprint() - before)
    }
    let repos = index.repos.values
    print("""
        code-terms scan: repos \(repos.count), named \(repos.filter { $0.name != nil }.count), \
        glossary \(repos.map(\.glossary.count).reduce(0, +)), skills \(repos.map(\.skills.count).reduce(0, +)), \
        dependencies \(repos.map(\.dependencies.count).reduce(0, +)), home skills \(index.user.count)
        code-terms scan ms: \(times.map { String(format: "%.1f", $0) }.joined(separator: ", "))
        code-terms footprint growth KB: \(growth.map { String($0 / 1024) }.joined(separator: ", "))
        """)

    // Launch as the app does it: scan, hand over, watch, replay a week of history.
    let before = footprint()
    let lexicon = try Lexicon(paths: .temporary())
    let terms = CodeTerms(code: code, home: home, lexicon: lexicon)
    let start = clock.now
    await terms.start()
    let started = clock.now - start
    print("""
        code-terms start (scan + replay) ms: \(String(format: "%.0f", milliseconds(started))), \
        current repo found: \(await terms.currentRepo != nil), code Terms: \(await lexicon.codeTerms.count), \
        footprint growth KB: \((footprint() - before) / 1024)
        """)
    await terms.stop()
    #expect(times.max() ?? .infinity < 1000)
    #expect(growth.max() ?? .max < 5 << 20)
}

/// Waits for `repo` to become current, or 10 s.
private func becomes(_ terms: CodeTerms, _ repo: String) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await current in terms.changes where current == repo { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

@Test(.enabled(if: measuring)) func codeTermsMeasureTouchToCurrent() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "code-terms-\(UUID().uuidString)")
    let code = root.appending(path: "code")
    for repo in ["quaxly", "zentrik"] {
        try FileManager.default.createDirectory(at: code.appending(path: repo), withIntermediateDirectories: true)
    }
    let lexicon = try Lexicon(paths: .temporary())
    let terms = CodeTerms(code: code, home: root.appending(path: "home"), lexicon: lexicon)
    await terms.start()
    // Settle on quaxly first, so no change from the setup is still waiting to be read.
    try "".write(to: code.appending(path: "quaxly/file.txt"), atomically: false, encoding: .utf8)
    #expect(await becomes(terms, "quaxly"))
    let clock = ContinuousClock()
    var times: [Double] = []
    for round in 0..<10 {
        let repo = round.isMultiple(of: 2) ? "zentrik" : "quaxly"
        let start = clock.now
        try "\(round)".write(to: code.appending(path: "\(repo)/file.txt"), atomically: false, encoding: .utf8)
        guard await becomes(terms, repo) else { break }
        times.append(milliseconds(clock.now - start))
    }
    await terms.stop()
    try? FileManager.default.removeItem(at: root)
    print("code-terms touch to current ms: \(times.map { String(format: "%.0f", $0) }.joined(separator: ", "))")
    #expect(times.count == 10 && times.max() ?? .infinity < 1000)
}
