import Foundation

/// A point on the host clock (mach absolute time, in nanoseconds). Key events,
/// audio buffers and the paste all stamp this clock, so lag is one subtraction.
public struct HostTime: Comparable, Hashable, Sendable, Codable {
    public let nanoseconds: UInt64
    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    public static func now() -> HostTime {
        HostTime(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }
    public static func < (a: HostTime, b: HostTime) -> Bool { a.nanoseconds < b.nanoseconds }
    public func duration(since earlier: HostTime) -> Duration {
        .nanoseconds(Int64(nanoseconds) - Int64(earlier.nanoseconds))
    }
}

/// Lexicon's one stored and transmitted audio format: 16 kHz mono 16-bit PCM (#4).
public enum PCM16k {
    public static let sampleRate = 16_000
}

/// A slice of 16 kHz mono Int16 audio, in capture order.
public struct PCMChunk: Sendable {
    public let index: Int
    public let samples: [Int16]
    public init(index: Int, samples: [Int16]) {
        self.index = index
        self.samples = samples
    }
}

/// The chunks of one Dictation as they are written to disk. Finishes when the
/// LiveCapture stops. A chunk is yielded only after it was handed to `write()`, so
/// anything a consumer sees is already in the page cache (survives an app crash).
public typealias AudioFeed = AsyncStream<PCMChunk>

/// A whole Dictation's audio in RAM (1.92 MB per minute). RAM is the primary copy
/// during a Dictation; the CAF file is the backup that survives a crash (#4).
public struct AudioClip: Sendable {
    public let samples: [Int16]
    public init(samples: [Int16]) { self.samples = samples }
    public var duration: Duration { .milliseconds(samples.count * 1000 / PCM16k.sampleRate) }

    /// Replays the clip as a feed, so retry, recovery and eval go through the
    /// same streaming path as a live Dictation. One engine path, not two.
    public func replay(chunkMilliseconds: Int = 100) -> AudioFeed {
        // TODO: split `samples` into chunkMilliseconds slices and yield them in order, then finish.
        fatalError("not implemented")
    }
}
