import Foundation
import Testing

// runChild (Tests/TestSupport/ChildProcess.swift), the one way a test runs a child process.

@Test(.timeLimit(.minutes(5))) func childrenThatExitAtOnceAllReturn() async throws {
    // waitUntilExit lost about one fast exit in 7,000, so this many catch it about half the time.
    try await withThrowingTaskGroup(of: Int32.self) { group in
        for index in 0..<5_000 {
            if index >= 16 { #expect(try await group.next() == 0) }
            group.addTask { try await runChild(URL(filePath: "/usr/bin/true"), []).status }
        }
        for try await status in group { #expect(status == 0) }
    }
}

@Test(.timeLimit(.minutes(1))) func aChildsStatusAndAllItsOutputComeBack() async throws {
    // 200 KB, more than a pipe holds, so the output must be read while the child runs.
    let child = try await runChild(URL(filePath: "/bin/sh"), ["-c", "yes | head -n 100000; echo done >&2; exit 3"])
    #expect(child.status == 3)
    #expect(child.output == String(repeating: "y\n", count: 100_000) + "done\n")
}

