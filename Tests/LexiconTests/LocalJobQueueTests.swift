import Foundation
import Synchronization
import Testing
@testable import Transcription

// The local job queue's line, driven directly: a job still waiting for
// its turn whose task is cancelled leaves the line at once, throws CancellationError
// and never runs its body. Each step waits on a signal (`untilWaiting`, a stream), so
// nothing depends on machine speed, and a missing signal fails at the time limit.

@Test(.timeLimit(.minutes(1))) func aWaitingJobWhoseTaskIsCancelledLeavesTheLineAndNeverRuns() async throws {
    let queue = LocalJobQueue()
    let log = RunLog()
    let (release, releasing) = AsyncStream<Void>.makeStream()
    let (started, starting) = AsyncStream<Void>.makeStream()

    let first = Task {
        try await queue.run(.background) { () async throws -> Void in
            starting.yield()
            for await _ in release { break }  // holds the Neural Engine until released
            await log.append("first")
        }
    }
    for await _ in started { break }
    let cancelled = Task {
        try await queue.run(.background) { () async throws -> Void in await log.append("cancelled") }
    }
    await queue.untilWaiting(atLeast: 1)
    let kept = Task {
        try await queue.run(.background) { () async throws -> Void in await log.append("kept") }
    }
    await queue.untilWaiting(atLeast: 2)
    #expect(await queue.waiting == 2)

    // The first job still holds the Neural Engine: only the cancelled job may leave the line.
    cancelled.cancel()
    await queue.untilWaiting(atMost: 1)
    #expect(await queue.waiting == 1)

    releasing.yield()
    try await first.value
    try await kept.value
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    // The cancelled body never ran; the job that stayed in line ran after the first.
    #expect(await log.names == ["first", "kept"])
}

@Test(.timeLimit(.minutes(1))) func aJobCancelledAsItsTurnComesNeverRuns() async throws {
    // The cancel lands while the job ahead is finishing, so the turn may reach the
    // cancelled job before it leaves the line. Many rounds, since that is a race.
    for _ in 0..<300 {
        let queue = LocalJobQueue()
        let log = RunLog()
        let (release, releasing) = AsyncStream<Void>.makeStream()
        let (started, starting) = AsyncStream<Void>.makeStream()
        let toCancel = Mutex<Task<Void, any Error>?>(nil)

        let first = Task {
            try await queue.run(.background) { () async throws -> Void in
                starting.yield()
                for await _ in release { break }
                toCancel.withLock { $0 }?.cancel()  // just before this job hands its turn over
            }
        }
        for await _ in started { break }
        let late = Task { try await queue.run(.background) { () async throws -> Void in await log.append("late") } }
        toCancel.withLock { $0 = late }
        await queue.untilWaiting(atLeast: 1)

        releasing.yield()
        try await first.value
        _ = try? await late.value
        if await log.names != [] {
            Issue.record("a job cancelled while it waited ran when its turn came")
            return
        }
    }
}

// MARK: Helpers

private actor RunLog {
    private(set) var names: [String] = []
    func append(_ name: String) { names.append(name) }
}
