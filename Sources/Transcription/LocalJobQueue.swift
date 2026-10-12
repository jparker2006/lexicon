/// One job at a time on the Neural Engine, live before background: a `.live`
/// waiter goes ahead of every queued `.background` one (recovery, Retry), so a
/// live Dictation never waits behind them. A running job is never aborted; a
/// job is one window of audio (about 0.1 s), so a long Retry yields between
/// windows. Each `LocalTranscriber` runs its model calls through one.
public actor LocalJobQueue {
    private var busy = false
    private var live: [CheckedContinuation<Void, Never>] = []
    private var background: [CheckedContinuation<Void, Never>] = []
    /// Callers of `untilWaiting`, woken each time a job joins the wait.
    private var watchers: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Jobs waiting for their turn, not counting the one running.
    var waiting: Int { live.count + background.count }

    /// Returns once at least `count` jobs wait for their turn: a test's signal that
    /// a job is queued, with no clock and no polling.
    func untilWaiting(atLeast count: Int) async {
        while waiting < count { await withCheckedContinuation { watchers.append($0) } }
    }

    /// Runs `job` when it is this caller's turn.
    public func run<T: Sendable>(_ priority: LocalPriority,
                                 _ job: @Sendable () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiter in
                switch priority {
                case .live: live.append(waiter)
                case .background: background.append(waiter)
                }
                for watcher in watchers { watcher.resume() }
                watchers = []
            }
        }
        busy = true
        defer { handOver() }
        return try await job()
    }

    private func handOver() {
        if !live.isEmpty {
            live.removeFirst().resume()
        } else if !background.isEmpty {
            background.removeFirst().resume()
        } else {
            busy = false
        }
    }
}
