#if DEBUG
import Foundation
import Synchronization

/// Runs `tool` and returns its exit status and its stdout and stderr together.
/// No thread blocks on the child: its exit and the end of its output each
/// arrive by callback, and the result waits for both. Never `waitUntilExit`:
/// it sleeps in the calling thread's run loop for a wakeup that is sometimes
/// lost when the child exits quickly, which once hung a check for 14 minutes.
@discardableResult
func runChild(_ tool: String, _ arguments: [String], environment: [String: String]? = nil)
    async throws -> (status: Int32, output: String)
{
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    if let environment { process.environment = environment }
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

/// Runs `tool` and fails unless it exits 0.
func run(_ tool: String, _ arguments: [String]) async throws {
    let (status, output) = try await runChild(tool, arguments)
    guard status == 0 else {
        throw HarnessError("\(tool) \(arguments.joined(separator: " ")) exited \(status): \(output.suffix(200))")
    }
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
#endif
