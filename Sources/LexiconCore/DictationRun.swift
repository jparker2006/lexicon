public import LexiconDomain
import AudioCapture
import Transcription
import Cleanup

// One run's values: what it starts from (`RunStart`), how its capture ends
// (`RunEnd`), what it hands `land` (`DictationRun`) and what it reports
// (`DictationResult`).

extension Conductor {
    /// Everything `land` needs about one Dictation past fn-up, as one value, so
    /// live, waiting, retry and recovery hand over the same thing (retry,
    /// recovery and a waiting Dictation's later try land it with `target: nil`
    /// and their own `cleaning` from `cleanup.begin(plan:)`).
    struct DictationRun: Sendable {
        let id: DictationID
        let origin: DictationOrigin
        let purpose: DictationPurpose
        let context: AppContext
        /// RAM copy of the audio, for the waiting branch's next transcription. nil
        /// once a waiting Dictation's whole audio is on disk: it is read back per try.
        var clip: AudioClip?
        var cleaning: CleanupSession
        /// Live: `Preferences.cleanupDeadline` (about 450 ms). Retry and recovery: seconds (nobody waits).
        let cleanupDeadline: Duration
        let access: CloudAccess?
        /// nil: never typed (recovery, retry). No public init exists to make one up.
        let target: Destination.Target?
        var releasedAt: HostTime?
        /// The status before this landing, for `DictationStatus.landed`.
        var previous: DictationStatus?
        /// nil when nobody waits for the text (recovery).
        let hold: LatencyHold?

        /// History's Retry: the only run that lands on a settled row.
        var isRetry: Bool { previous?.isTerminal == true }

        /// Jake waits at the cursor only when the text may still be typed.
        var localPriority: LocalPriority { target == nil ? .background : .live }
    }
}

/// How the capture phase of a run ends.
enum RunEnd: Sendable {
    case stop(at: HostTime)
    case cancel
    case discard

    /// A recording that ends in a transcription, as opposed to a dropped tap.
    var isStop: Bool {
        switch self {
        case .stop, .cancel: true
        case .discard: false
        }
    }
}

struct RunStart: Sendable {
    let id: DictationID
    let input: AudioInput
    let preferences: Preferences
    let origin: DictationOrigin
    let purpose: DictationPurpose
    let began: HostTime
}

/// What a finished run reports (eval prints it as one JSON line per clip).
public struct DictationResult: Sendable {
    public let id: DictationID
    /// nil: discarded (a stray tap; nothing was recorded, nothing lost).
    public let status: DictationStatus?
    public let versions: TextVersions?
    /// AI cleanup accepted, or why the rules-only text was used.
    public let cleanup: CleanupOutcome?
    public let model: SpeechModel?
    /// fn-up (or end of file) -> Cmd-V posted.
    public let lag: Duration?
    public let attempts: [AttemptRecord]

    static func nothing(_ id: DictationID) -> DictationResult {
        DictationResult(id: id, status: nil, versions: nil, cleanup: nil, model: nil, lag: nil, attempts: [])
    }
}
