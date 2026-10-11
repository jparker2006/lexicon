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
    private let refused = Atomic<Int>(0)

    init(capacityFrames: Int) {
        precondition(capacityFrames > 0)
        capacity = capacityFrames
        storage = .allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0)
    }
    deinit { storage.deallocate() }

    /// Producer only. Real-time safe. Returns frames accepted; the rest did not
    /// fit because the writer fell 2 s behind.
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

    /// The mic's write: it can't wait for room (a file can), so what does not
    /// fit is dropped and counted. Real-time safe.
    func writeOrDrop(_ frames: UnsafeBufferPointer<Float>) {
        let accepted = write(frames)
        if accepted < frames.count { refused.add(frames.count - accepted, ordering: .relaxed) }
    }

    /// Frames `writeOrDrop` dropped so far.
    var dropped: Int { refused.load(ordering: .relaxed) }

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
    /// Settled, possibly with nil.
    var isSettled: Bool { state.withLock { $0.settled } }

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

/// Fans each chunk's level out to every `Recorder.levels` observer. Observers
/// stay subscribed across captures until their stream goes away.
final class LevelBroadcaster: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<AudioLevel>.Continuation]>([:])

    /// Newest only: the meter wants the latest level, and a slow observer must not
    /// hold up the writer queue.
    func subscribe() -> AsyncStream<AudioLevel> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AudioLevel>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Weak: a stream that is never cancelled must not keep the broadcaster alive.
        continuation.onTermination = { [weak self] _ in
            self?.subscribers.withLock { $0[id] = nil }
        }
        subscribers.withLock { $0[id] = continuation }
        return stream
    }

    func send(_ level: AudioLevel) {
        subscribers.withLock { observers in
            for continuation in observers.values { continuation.yield(level) }
        }
    }
}

/// Where the tail after fn-up ends: at the first 40 ms of quiet, never past
/// 200 ms after fn-up. Pure: fed the 16 kHz samples in capture order, before
/// and after the release, so it can be tested without a mic or a clock.
///
/// Why adaptive: #4 says keep capturing ~200 ms after release so the last word
/// is never cut; #8 says send finalize the instant fn comes up. A fixed 200 ms
/// tail would add 200 ms to every Dictation's lag. So the tail ends as soon as
/// the signal is quiet, and 200 ms is only the cap. Values are #18's.
///
/// The cap is counted in audio, not on a clock: the mic delivers audio in real
/// time, so the two agree, and a stalled device is the capture's problem (it
/// has a wall-clock backstop), not this policy's.
struct Tail: Sendable {
    var cap: Duration = .milliseconds(200)
    var quietWindow: Duration = .milliseconds(40)
    var quietBelowDBFS: Double = -45

    /// Quiet is judged per 10 ms block.
    static let blockSamples = PCM16k.sampleRate / 100

    private(set) var isOver = false
    /// Samples the tail may still take. nil until fn-up.
    private var budget: Int?
    private var quietRun = 0
    private var blockFill = 0
    private var blockEnergy: Double = 0

    /// Before fn-up keeps everything. After it, returns how many of `samples`
    /// belong to the tail: fewer than given means the tail just ended.
    mutating func keep(_ samples: UnsafeBufferPointer<Int16>) -> Int {
        var kept = 0
        while kept < samples.count, !isOver {
            let take = min(Self.blockSamples - blockFill, samples.count - kept, budget ?? .max)
            for sample in samples[kept..<kept + take] { blockEnergy += Double(sample) * Double(sample) }
            blockFill += take
            kept += take
            if let budget { self.budget = budget - take }
            if blockFill == Self.blockSamples { closeBlock() }
            if let budget, budget == 0 || quietRun >= Self.samples(quietWindow) { isOver = true }
        }
        return kept
    }

    /// fn-up was `late` ago: the cap counts from fn-up, not from this call.
    mutating func release(late: Duration) {
        let budget = max(0, Self.samples(cap) - Self.samples(late))
        self.budget = budget
        isOver = budget == 0 || quietRun >= Self.samples(quietWindow)
    }

    private mutating func closeBlock() {
        let rms = (blockEnergy / Double(Self.blockSamples)).squareRoot()
        let quiet = 20 * log10(max(rms, 1e-9) / 32_768) < quietBelowDBFS
        quietRun = quiet ? quietRun + Self.blockSamples : 0
        blockFill = 0
        blockEnergy = 0
    }

    private static func samples(_ duration: Duration) -> Int {
        Int((duration / .seconds(1) * Double(PCM16k.sampleRate)).rounded())
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
