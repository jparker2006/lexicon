import Foundation
import Synchronization
import Testing

/// Runs `executable` and returns its exit status and its stdout and stderr together.
/// No thread blocks on the child: its exit and the end of its output each arrive
/// by callback, and the result waits for both. Never `waitUntilExit`: that sleeps
/// in the calling thread's run loop for a wakeup that is sometimes lost when the
/// child exits quickly. Cancelling the task, as a time limit does, terminates the
/// child, so a hung child fails its test instead of holding up the whole run.
func runChild(_ executable: URL, _ arguments: [String]) async throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let output = ChildOutput()
    let done = DispatchGroup()
    done.enter()  // the child has exited
    done.enter()  // its output has ended
    process.terminationHandler = { _ in done.leave() }
    pipe.fileHandleForReading.readabilityHandler = { handle in
        if output.append(handle.availableData) {
            handle.readabilityHandler = nil
            done.leave()
        }
    }
    try process.run()
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in done.notify(queue: .global()) { continuation.resume() } }
    } onCancel: {
        process.terminate()
    }
    return (process.terminationStatus, output.text)
}

/// A child's output as it arrives, from whichever thread the pipe calls back on.
private final class ChildOutput: Sendable {
    private let state = Mutex((data: Data(), ended: false))

    /// Adds a chunk; an empty one is the end. True only the first time the end
    /// arrives, so the end is counted once however often it is reported.
    func append(_ chunk: Data) -> Bool {
        state.withLock { state in
            guard !state.ended else { return false }
            if chunk.isEmpty { state.ended = true; return true }
            state.data.append(chunk)
            return false
        }
    }

    var text: String { state.withLock { String(decoding: $0.data, as: UTF8.self) } }
}

@Test(.timeLimit(.minutes(1))) func childrenThatExitAtOnceAllReturn() async throws {
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

