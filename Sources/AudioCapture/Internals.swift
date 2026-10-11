import Foundation
import Synchronization
import LexiconDomain

/// Single-producer single-consumer lock-free ring of Float32 frames at the
/// hardware rate. Producer: the real-time sink-node block (memcpy only: no
/// allocation, no locks, no dispatch). Consumer: the writer queue.
/// 2 s of 48 kHz mono = 384 KB, preallocated.
final class SPSCRing: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init(capacityFrames: Int) {
        storage = .allocate(capacity: capacityFrames)
    }
    deinit { storage.deallocate() }

    /// Real-time thread. Returns frames dropped if the writer fell 2 s behind (logged, never blocks).
    func write(_ frames: UnsafeBufferPointer<Float>) -> Int { fatalError("not implemented") }

    /// Writer queue.
    func read(into buffer: inout [Float]) -> Int { fatalError("not implemented") }
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
    var fullSyncEvery: Duration = .seconds(1)
    var minimumFreeBytes: Int64 = 1_000_000_000
}
