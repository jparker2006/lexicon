/// One job at a time on the Neural Engine, live before background: a `.live`
/// waiter goes ahead of every queued `.background` one (recovery, Retry), so a
/// live Dictation never waits behind them. A running job is never aborted; a
/// job is one window of audio (about 0.1 s), so a long Retry yields between
/// windows. A waiting job whose task is cancelled leaves at once, so a lost
/// race, a cancelled Retry or a call past its limit frees its place instead of
/// running later. Each `LocalTranscriber` runs its model calls through one.
public actor LocalJobQueue {
    private struct Waiter {
        let id: UInt64
        let turn: CheckedContinuation<Void, any Error>
    }

    private var busy = false
    private var live: [Waiter] = []
    private var background: [Waiter] = []
    private var nextID: UInt64 = 0
    /// Callers of `untilWaiting`, woken each time a job joins or leaves the wait.
    private var watchers: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Jobs waiting for their turn, not counting the one running.
    var waiting: Int { live.count + background.count }

    /// Callers parked in `untilWaiting`.
    var watching: Int { watchers.count }

    /// Returns once at least `count` jobs wait for their turn: a test's signal that
    /// a job is queued, with no clock and no polling. Also returns when its task is
    /// cancelled, so a test whose job never queues fails at its time limit, not hangs.
    func untilWaiting(atLeast count: Int) async {
        await untilWaiting { $0 >= count }
    }

    /// Returns once at most `count` jobs wait: a test's signal that a cancelled job left.
    func untilWaiting(atMost count: Int) async {
        await untilWaiting { $0 <= count }
    }

    private func untilWaiting(_ done: (Int) -> Bool) async {
        while !done(waiting), !Task.isCancelled {
            await withTaskCancellationHandler {
                await withCheckedContinuation { watchers.append($0) }
            } onCancel: {
                Task { await self.wakeWatchers() }
            }
        }
    }

    private func wakeWatchers() {
        for watcher in watchers { watcher.resume() }
        watchers = []
    }

    /// Runs `job` when it is this caller's turn. Throws `CancellationError`, and
    /// never runs `job`, when the caller's task is cancelled while it waits.
    public func run<T: Sendable>(_ priority: LocalPriority,
                                 _ job: @Sendable () async throws -> T) async throws -> T {
        if busy {
            nextID += 1
            let id = nextID
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (turn: CheckedContinuation<Void, any Error>) in
                    guard !Task.isCancelled else { return turn.resume(throwing: CancellationError()) }
                    switch priority {
                    case .live: live.append(Waiter(id: id, turn: turn))
                    case .background: background.append(Waiter(id: id, turn: turn))
                    }
                    wakeWatchers()
                }
            } onCancel: {
                Task { await self.leave(id) }
            }
        }
        busy = true
        defer { handOver() }
        return try await job()
    }

    /// A cancelled waiter gives up its place. One whose turn already came runs as usual.
    private func leave(_ id: UInt64) {
        if let index = live.firstIndex(where: { $0.id == id }) {
            live.remove(at: index).turn.resume(throwing: CancellationError())
        } else if let index = background.firstIndex(where: { $0.id == id }) {
            background.remove(at: index).turn.resume(throwing: CancellationError())
        }
        wakeWatchers()
    }

    private func handOver() {
        if !live.isEmpty {
            live.removeFirst().turn.resume()
        } else if !background.isEmpty {
            background.removeFirst().turn.resume()
        } else {
            busy = false
        }
    }
}
