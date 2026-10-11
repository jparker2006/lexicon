public import Foundation
public import LexiconDomain

/// Where a LiveCapture's audio comes from: the audio-source seam (#14). An enum,
/// not a public protocol, so no real-time types leak out of this module. Both
/// cases run the same ring -> converter -> file + feed path, so a WAV test
/// exercises the exact code the mic uses.
public enum AudioInput: Sendable, Hashable {
    /// nil device = built-in mic, falling back in a fixed order when the lid is closed (#4).
    case microphone(deviceUID: String?)
    /// Any format AVAudioFile reads; converted to 16 kHz like the mic.
    case file(URL, pace: FilePace)
}

public enum FilePace: Sendable, Hashable {
    /// Chunks arrive at the speed of speech: honest streaming lag for eval and e2e.
    case realtime
    /// As fast as the writer can drain: unit tests.
    case asFastAsPossible
}

public enum RecorderError: Error, Sendable {
    case micPermissionDenied
    case noInputDevice
    case alreadyRecording
    case engineFailed(String)
    case unreadableFile(URL)
}

/// One sound level per chunk, for the recording indicator (look is #18).
public struct AudioLevel: Sendable { public let rms: Float }

/// Captures audio for one Dictation at a time.
///
/// Hides (#4): AVAudioEngine plus AVAudioSinkNode (10.7 ms buffers on the
/// real-time thread, which only memcpys into `SPSCRing`), the writer queue that
/// drains every ~50-100 ms, AVAudioConverter (MinimumPhase, .max) to 16 kHz mono
/// Int16, `AudioFileWritePackets` into a CAF whose data size stays -1 while open,
/// F_FULLFSYNC every 1 s off the audio thread, device pinning, engine rebuild on
/// a configuration change (same file keeps growing, gap logged), the disk-low
/// and write-error fallback to RAM, all-zero-input detection, and the adaptive tail.
/// Never touches outputNode or mainMixerNode.
///
/// Threads: the Core Audio IO thread (sink node) and one serial writer queue.
/// All engine and file state is confined to the writer queue.
public final class Recorder: @unchecked Sendable {
    public init() { fatalError("not implemented") }

    /// At launch and after every stop, so `start` only has to start hardware.
    public func prepare(_ input: AudioInput) { fatalError("not implemented") }

    /// fn-down. Starts the engine, then (on the writer queue, not in front of the
    /// hardware start) creates `file`. Returns as soon as capture is running.
    ///
    /// Ownership handoff: while the LiveCapture is open, this module is the only
    /// writer of `file`. After `stop`, the file belongs to History (#4).
    /// fn never waits (#18): if the previous LiveCapture is still in its tail, its
    /// tail ends now and the new capture starts at once.
    public func start(_ input: AudioInput, writingTo file: URL) async throws(RecorderError) -> LiveCapture {
        fatalError("not implemented")
    }

    /// Levels of whatever is recording, for the indicator. Any number of observers.
    public var levels: AsyncStream<AudioLevel> { fatalError("not implemented") }
}

/// How a LiveCapture ends.
public enum Ending: Sendable, Hashable {
    /// Jake released fn at this time: capture the adaptive tail (TailPolicy), then stop.
    case released(at: HostTime)
    /// Cancel, discard, sleep: stop now, no tail.
    case immediately
}

/// What a stopped LiveCapture hands back. `clip` is the RAM copy (primary);
/// the file is flushed and closed in the background, in parallel with
/// transcription, never in front of insertion (#4).
public struct Take: Sendable {
    public let clip: AudioClip
    public let summary: AudioSummary
}

public enum CaptureProblem: Sendable, Hashable {
    /// Exactly-zero samples in the first ~300 ms: missing permission or a dead device (#4).
    case silentInput
    /// AirPods stem mute (AVAudioApplication input mute).
    case inputMuted
    /// Under 1 GB free or a write failed: continuing in RAM only.
    case diskTrouble
    case deviceChanged
}

/// Signals a caller can watch without owning the LiveCapture. Copyable on purpose,
/// so it can be handed to a task while the LiveCapture itself stays with its owner.
public struct CaptureSignals: Sendable {
    /// Host time of the first real buffer: show "listening" now, not on key-down (#4).
    public func firstAudio() async -> HostTime? { fatalError("not implemented") }
    public var problems: AsyncStream<CaptureProblem> { fatalError("not implemented") }
    /// File inputs only: host time the last sample was read (the "release" of a
    /// file Dictation). Never returns for the microphone.
    public func inputEnded() async -> HostTime? { fatalError("not implemented") }
}

/// One open capture. Non-copyable: it can be stopped exactly once (`stop` is
/// consuming), and only by whoever holds it, so "who ends this Dictation's
/// audio" has a single answer enforced by the compiler.
///
/// If a LiveCapture is dropped without `stop`, the Recorder finalizes it on the
/// next `start` or at quit, keeping the audio. Dropping never loses audio.
public struct LiveCapture: ~Copyable, Sendable {
    let core: CaptureCore

    /// 16 kHz chunks in capture order; finishes after the last chunk of the tail.
    public var feed: AudioFeed { core.feed }
    public var signals: CaptureSignals { core.signals }

    public consuming func stop(_ ending: Ending) async -> Take {
        // TODO: if .released: keep capturing until TailPolicy says stop (cap 200 ms);
        // drain the ring, write the last packets, finish `feed`, return the RAM clip.
        // Then, on the writer queue: F_FULLFSYNC, AudioFileClose (writes the real size).
        fatalError("not implemented")
    }
}

/// Internal shared state of one LiveCapture, confined to the writer queue.
final class CaptureCore: @unchecked Sendable {
    var feed: AudioFeed { fatalError("not implemented") }
    var signals: CaptureSignals { fatalError("not implemented") }
}
