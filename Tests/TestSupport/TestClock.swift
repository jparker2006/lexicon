import Foundation
import Synchronization

/// A clock that moves only when a test calls `advance`.
public final class TestClock: Clock, Sendable {
    public struct Instant: InstantProtocol {
        public var offset: Duration
        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let wake: CheckedContinuation<Void, any Error>
    }

    public init() {}

    private let state = Mutex<(now: Instant, sleepers: [Sleeper])>((Instant(offset: .zero), []))

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }
    /// Sleeps not yet due or cancelled.
    public var sleepers: Int { state.withLock { $0.sleepers.count } }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { wake in
                let now = state.withLock { state -> Bool? in
                    if Task.isCancelled { return nil }
                    if deadline <= state.now { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, wake: wake))
                    return false
                }
                switch now {
                case nil: wake.resume(throwing: CancellationError())
                case true?: wake.resume()
                case false?: break
                }
            }
        } onCancel: {
            let cancelled = state.withLock { state in
                state.sleepers.firstIndex { $0.id == id }.map { state.sleepers.remove(at: $0) }
            }
            cancelled?.wake.resume(throwing: CancellationError())
        }
    }

    /// Returns once exactly `count` sleeps are pending: a timer task reaches
    /// its sleep some time after it is started. Both waits also return when the
    /// test is cancelled, so its time limit fails it instead of spinning forever.
    public func waitForSleepers(_ count: Int) async {
        while sleepers != count, !Task.isCancelled { await Task.yield() }
    }

    /// Returns once a sleep due exactly `offset` after the clock's start is
    /// pending: a race deadline or a scripted reply, told apart by when they end.
    public func waitForSleep(endingAt offset: Duration) async {
        while !state.withLock({ $0.sleepers.contains { $0.deadline.offset == offset } }), !Task.isCancelled {
            await Task.yield()
        }
    }

    /// Moves time on and wakes every sleep that is now due.
    public func advance(by duration: Duration) async {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.wake.resume() }
    }
}
