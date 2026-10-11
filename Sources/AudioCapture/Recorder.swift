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
    /// Core Audio did not start the engine within `Microphone.startLimit`, or
    /// the Allow prompt was still unanswered after `Microphone.promptLimit`.
    case startTimedOut
    case unreadableFile(URL)
}

/// One sound level per chunk, for the recording indicator (look is #18).
public struct AudioLevel: Sendable { public let rms: Float }

/// Captures audio for one Dictation at a time.
///
/// Hides (#4): AVAudioEngine plus AVAudioSinkNode (10.7 ms buffers on the
/// real-time thread, which only copies into `SPSCRing`), the writer queue that
/// drains every 100 ms, AVAudioConverter (MinimumPhase, .max) to 16 kHz mono
/// Int16, `AudioFileWritePackets` into a CAF whose data size stays -1 while open,
/// F_FULLFSYNC every 1 s off the audio thread, device pinning, engine rebuild on
/// a configuration change (same file keeps growing, gap logged), the disk-low
/// and write-error fallback to RAM, and the adaptive tail.
/// Never touches outputNode or mainMixerNode.
///
/// Threads: the Core Audio IO thread (sink node), the microphone's engine
/// queue, and one serial writer queue for every file and converter.
public final class Recorder: Sendable {
    /// The one serial writer queue: drains, converts, writes, syncs, closes.
    private let writerQueue = DispatchQueue(label: "lexicon.audio.writer", qos: .userInitiated)
    private let broadcaster = LevelBroadcaster()
    let microphone: Microphone
    let policy: FlushPolicy

    public convenience init() {
        self.init(hardware: .system, policy: FlushPolicy())
    }

    /// Tests swap in fake mic hardware (no mic) or a flush policy (a full disk).
    init(hardware: MicHardware = .system, policy: FlushPolicy = FlushPolicy()) {
        microphone = Microphone(hardware: hardware)
        self.policy = policy
    }

    /// At launch, so the first `start` only has to start hardware. After every
    /// stop the microphone prepares the next engine itself. A file has nothing to warm up.
    public func prepare(_ input: AudioInput) {
        guard case .microphone(let uid) = input else { return }
        microphone.prepare(deviceUID: uid)
    }

    /// fn-down at `keyDown`. Starts the engine, then (on the writer queue, not in
    /// front of the hardware start) creates `file`. Returns as soon as capture is
    /// running. The summary's start gap counts from `keyDown`.
    ///
    /// Ownership handoff: while the LiveCapture is open, this module is the only
    /// writer of `file`. After `stop`, the file belongs to History (#4).
    /// fn never waits (#18): if the previous LiveCapture is still in its tail, its
    /// tail ends now and the new capture starts at once.
    public func start(_ input: AudioInput, writingTo file: URL,
                      since keyDown: HostTime = .now()) async throws(RecorderError) -> LiveCapture {
        let source: any CaptureSource
        var policy = policy
        switch input {
        case .microphone(let uid):
            source = try await microphone.start(deviceUID: uid, keyDown: keyDown)
        case .file(let url, let pace):
            source = try FileSource(url: url, pace: pace)
            if pace == .asFastAsPossible { policy.drainEvery = .milliseconds(5) }
        }
        guard let core = CaptureCore(source: source, file: file, policy: policy, queue: writerQueue, startedAt: keyDown,
                                     onLevel: broadcaster.send) else {
            source.stop()
            throw .engineFailed("no converter from \(source.firstSegment.rate) Hz to 16 kHz")
        }
        core.begin()
        return LiveCapture(core: core)
    }

    /// Returns once every stopped or dropped capture's file is synced and closed.
    /// For quit, and for tests that read a file right after `stop`.
    public func settle() async {
        await withCheckedContinuation { continuation in writerQueue.async { continuation.resume() } }
    }

    /// Levels of whatever is recording, one per chunk, for the indicator. Each call
    /// is a new stream (any number of observers) that keeps only the newest level,
    /// so a slow observer never backs up the writer.
    public var levels: AsyncStream<AudioLevel> { broadcaster.subscribe() }
}

/// How a LiveCapture ends.
public enum Ending: Sendable, Hashable {
    /// Jake released fn at this time: capture the adaptive tail (`Tail`), then stop.
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
    let first: OneShot<HostTime>
    let end: OneShot<HostTime>
    public let problems: AsyncStream<CaptureProblem>

    /// Host time of the first real buffer: show "listening" now, not on key-down (#4).
    /// nil if the capture stopped before any audio arrived.
    public func firstAudio() async -> HostTime? { await first.value() }
    /// File inputs only: host time the last sample was read (the "release" of a
    /// file Dictation). nil for the microphone, and for a file stopped before its
    /// end; either way it returns only once the capture stops. Cancelling the
    /// waiting task returns nil at once.
    public func inputEnded() async -> HostTime? { await end.value() }
}

/// One open capture. Non-copyable: it can be stopped exactly once (`stop` is
/// consuming), and only by whoever holds it, so "who ends this Dictation's
/// audio" has a single answer enforced by the compiler.
///
/// If a LiveCapture is dropped without `stop`, it stops itself in the
/// background: the ring is drained, the file synced and closed. Dropping never
/// loses audio.
public struct LiveCapture: ~Copyable, Sendable {
    let core: CaptureCore

    /// 16 kHz chunks in capture order; finishes after the last chunk of the tail.
    public var feed: AudioFeed { core.feed }
    public var signals: CaptureSignals { core.signals }

    /// Returns once the last packet is written and `feed` has finished. The
    /// F_FULLFSYNC and close (which writes the real size) run after, on the
    /// writer queue, in parallel with transcription (`Recorder.settle` waits).
    /// `.released` keeps capturing until the last word is in: 40 ms of quiet,
    /// at most 200 ms after fn-up. A file read to its end has no tail left.
    public consuming func stop(_ ending: Ending) async -> Take {
        await core.stop(ending)
    }

    deinit { core.dropped() }
}
