import Foundation
import Synchronization
import LexiconDomain

/// Single-producer single-consumer lock-free ring of Float32 frames at the
/// hardware rate. Producer: the real-time sink-node block (memcpy only: no
/// allocation, no locks, no dispatch), or the file reader. Consumer: the writer queue.
/// 2 s of 48 kHz mono = 384 KB, preallocated.
///
/// `head` and `tail` count frames ever written and read, so they never wrap;
/// the slot is `count % capacity`.
///
/// `@unchecked Sendable`: one producer and one consumer by contract. Each side
/// writes only its own counter and the slots between them, published with
/// release and read with acquire.
final class SPSCRing: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutableBufferPointer<Float>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init(capacityFrames: Int) {
        precondition(capacityFrames > 0)
        capacity = capacityFrames
        storage = .allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0)
    }
    deinit { storage.deallocate() }

    /// Producer only. Real-time safe. Returns frames accepted; the rest did not
    /// fit because the writer fell 2 s behind (the mic logs them as dropped).
    func write(_ frames: UnsafeBufferPointer<Float>) -> Int {
        let written = head.load(ordering: .relaxed)
        let read = tail.load(ordering: .acquiring)
        let count = min(frames.count, capacity - (written - read))
        guard count > 0, let source = frames.baseAddress else { return 0 }
        let start = written % capacity
        let first = min(count, capacity - start)
        (storage.baseAddress! + start).update(from: source, count: first)
        if count > first { storage.baseAddress!.update(from: source + first, count: count - first) }
        head.store(written + count, ordering: .releasing)
        return count
    }

    /// Consumer only. Returns frames copied into `buffer`, at most `buffer.count`.
    func read(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        let read = tail.load(ordering: .relaxed)
        let written = head.load(ordering: .acquiring)
        let count = min(buffer.count, written - read)
        guard count > 0, let destination = buffer.baseAddress else { return 0 }
        let start = read % capacity
        let first = min(count, capacity - start)
        destination.update(from: storage.baseAddress! + start, count: first)
        if count > first { (destination + first).update(from: storage.baseAddress!, count: count - first) }
        tail.store(read + count, ordering: .releasing)
        return count
    }
}

/// A value set once, awaited by any number of callers. Waiting is cancellable:
/// a cancelled waiter gets nil, so racing it in a task group never hangs.
final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var settled = false
        var value: Value?
        var waiters: [UInt64: CheckedContinuation<Value?, Never>] = [:]
        var cancelled: Set<UInt64> = []
        var nextID: UInt64 = 0
    }
    private let state = Mutex(State())

    /// The value if settled, without waiting.
    var current: Value? { state.withLock { $0.value } }

    /// First call wins; later calls are ignored.
    func settle(_ value: Value?) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value?, Never>] in
            guard !state.settled else { return [] }
            state.settled = true
            state.value = value
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    func value() async -> Value? {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> (Bool, Value?) in
                    if state.cancelled.remove(id) != nil { return (true, nil) }
                    if state.settled { return (true, state.value) }
                    state.waiters[id] = continuation
                    return (false, nil)
                }
                if ready.0 { continuation.resume(returning: ready.1) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Value?, Never>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                if !state.settled { state.cancelled.insert(id) }
                return nil
            }
            waiter?.resume(returning: nil)
        }
    }
}

/// Decides when the tail after fn-up may end. Pure.
///
/// Why adaptive: #4 says keep capturing ~200 ms after release so the last word
/// is never cut; #8 says send finalize the instant fn comes up. A fixed 200 ms
/// tail would add 200 ms to every Dictation's lag. So the tail ends as soon as
/// the signal after release is quiet, and 200 ms is only the cap. Values are #18's.
struct TailPolicy: Sendable {
    var cap: Duration = .milliseconds(200)
    var quietWindow: Duration = .milliseconds(40)
    var quietBelowDBFS: Float = -45

    enum Verdict: Sendable { case keepCapturing, stop }

    func verdict(sinceRelease: Duration, recentLevelsDBFS: [Float]) -> Verdict {
        // TODO: stop if sinceRelease >= cap, or if the last `quietWindow` of levels are all below threshold.
        fatalError("not implemented")
    }
}

/// The writer's flush schedule (#4): write() every chunk, F_FULLFSYNC every 1 s
/// (fsync fallback where unsupported), F_FULLFSYNC + close at stop.
struct FlushPolicy: Sendable {
    /// How often the writer queue drains the ring. Each drain writes packets of
    /// at most `chunk` of audio, so a feed chunk is about 100 ms.
    var drainEvery: Duration = .milliseconds(100)
    var chunk: Duration = .milliseconds(100)
    var fullSyncEvery: Duration = .seconds(1)
    var minimumFreeBytes: Int64 = 1_000_000_000
}
