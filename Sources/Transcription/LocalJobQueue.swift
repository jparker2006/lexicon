/// One job at a time on the Neural Engine, live before background: a `.live`
/// waiter goes ahead of every queued `.background` one (recovery, Retry), so a
/// live Dictation never waits behind them. A running job is never aborted
/// (about 80 ms). Each `LocalTranscriber` runs its model calls through one.
public actor LocalJobQueue {
    private var busy = false
    private var live: [CheckedContinuation<Void, Never>] = []
    private var background: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Jobs waiting for their turn, not counting the one running.
    public var waiting: Int { live.count + background.count }

    /// Runs `job` when it is this caller's turn.
    public func run<T: Sendable>(_ priority: LocalPriority,
                                 _ job: @Sendable () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiter in
                switch priority {
                case .live: live.append(waiter)
                case .background: background.append(waiter)
                }
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
