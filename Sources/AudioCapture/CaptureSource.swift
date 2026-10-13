import Foundation
import LexiconDomain

/// Where a capture's frames come from: the file reader thread, or the mic's
/// real-time sink block. Either way the producer writes mono Float32 frames at
/// a segment's rate into that segment's ring, and the writer queue drains it.
protocol CaptureSource: AnyObject, Sendable {
    /// The ring the producer writes when the capture starts.
    var firstSegment: Segment { get }
    /// Starts producing (a file starts its reader; the mic is already running).
    func start(_ events: SourceEvents)
    /// Stops the producer. The capture reads no ring after calling it, so a
    /// producer that stops a moment later loses nothing. Idempotent.
    func stop()
    /// Name of the input device, for History. nil for a file.
    var deviceName: String? { get }
    /// Device changes so far: the audio missed while the engine was rebuilt.
    var gaps: [Duration] { get }
    /// Audio the source failed to produce: a file's unread rest after a read error.
    var lostAudio: Duration { get }
}

/// One stretch of frames at one rate. The mic starts a new segment when a
/// device change rebuilds its engine, possibly at a new hardware rate.
struct Segment: Sendable {
    let ring: SPSCRing
    let rate: Double

    /// 2 s of audio: the writer may fall that far behind before frames drop.
    init(rate: Double) {
        self.rate = rate
        ring = SPSCRing(capacityFrames: Int(rate * 2))
    }

    var droppedAudio: Duration { .seconds(Double(ring.dropped) / rate) }
}

/// What a source reports to its capture. Each runs off the real-time thread.
struct SourceEvents: Sendable {
    /// Once, with the host time the first frames entered the ring.
    let firstAudio: @Sendable (HostTime) -> Void
    /// Once, when the source stops producing for good on its own: the time of
    /// the last sample for a file read to its end, nil when the input broke off.
    let ended: @Sendable (HostTime?) -> Void
    /// The producer moved to a new segment. The old one gets no more frames.
    let switched: @Sendable (Segment) -> Void
}
