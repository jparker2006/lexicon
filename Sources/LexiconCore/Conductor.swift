public import Foundation
import Synchronization
public import LexiconDomain
public import KeyInput
public import AudioCapture
public import Transcription
public import Cleanup
public import WordStore
public import History
public import AppText
public import Jev
public import Fixes

/// The owner of every Dictation's lifecycle, from fn-down to text at the cursor
/// and on through waiting, retry and recovery.
///
/// It is the only code that decides what happens next to a Dictation. It holds
/// no durable state: rows belong to History, audio bytes to the LiveCapture,
/// placements to AppText. Its own state is in memory only: the stop signal of
/// the Dictation that is recording (at most one: one mic) and the tasks of
/// Dictations still in flight (transcribing or waiting; any number).
///
/// Read `Conductor+Run.swift` top to bottom to trace one Dictation. Each step
/// is one call into the module that owns it; no step forwards further.
///
/// Isolation: its own actor, NOT the main actor, so a busy History window can
/// never delay fn-up -> text. Reentrant by design: while a run awaits the
/// LiveCapture, `handle(.dictationStopped)` runs and resumes it.
public actor Conductor<Destination: TextDestination> {
    let recorder: Recorder
    let speech: SpeechEngine
    let cleanup: Cleanup
    let lexicon: Lexicon
    let history: HistoryStore
    let destination: Destination
    let preferences: PreferencesStore
    let secrets: Secrets
    /// nil in headless runs (eval, tests).
    let keyboard: Keyboard?
    let fixes: FixEngine?
    let jev: JevClient?

    /// Stop signal of the Dictation that is recording. Single slot: one mic.
    var captureEnd: AsyncStream<RunEnd>.Continuation?
    var capturingID: DictationID?
    /// Dictations past stop that still need text (transcribing, waiting).
    var inFlight: [DictationID: Task<DictationResult, Never>] = [:]
    /// Live Dictations in fn-down order. A Dictation inserts only when every
    /// earlier one has inserted, been held, or gone waiting (#18: they insert in
    /// the order they were spoken). A waiting Dictation gives up its turn, so a
    /// network outage never blocks later text; its late insert passes InsertGuard.
    var insertOrder: [DictationID] = []
    /// A Dictation whose text is ready while an earlier one still holds the turn.
    var turnWaiters: [DictationID: CheckedContinuation<Void, Never>] = [:]
    var subscribers: [UUID: AsyncStream<ConductorEvent>.Continuation] = [:]

    public init(recorder: Recorder, speech: SpeechEngine, cleanup: Cleanup, lexicon: Lexicon, history: HistoryStore,
                destination: Destination, preferences: PreferencesStore, secrets: Secrets,
                keyboard: Keyboard?, fixes: FixEngine?, jev: JevClient?) {
        self.recorder = recorder
        self.speech = speech
        self.cleanup = cleanup
        self.lexicon = lexicon
        self.history = history
        self.destination = destination
        self.preferences = preferences
        self.secrets = secrets
        self.keyboard = keyboard
        self.fixes = fixes
        self.jev = jev
    }

    // MARK: Commands

    /// Every key command, one exhaustive switch. The single consumer of `Keyboard.commands`.
    public func handle(_ command: KeyCommand) {
        switch command {
        case .dictationBegan(let at):
            // fn never waits (#18): an earlier Dictation still finishing is fine; one
            // still in its 200 ms tail has its tail cut by `recorder.start`.
            guard captureEnd == nil else { return }  // recognizer guarantees one recording at a time
            let id = DictationID()
            insertOrder.append(id)
            let (ends, continuation) = AsyncStream<RunEnd>.makeStream()
            captureEnd = continuation
            capturingID = id
            let prefs = preferences.snapshot()   // the one snapshot this Dictation uses
            let start = RunStart(id: id, input: .microphone(deviceUID: prefs.microphoneUID), preferences: prefs,
                                 origin: .live, purpose: .type, began: at)
            // App Nap off from fn-down until the text lands (ended in `land`, or by `run` on any exit).
            let hold = LatencyHold(reason: "Dictation \(id)")
            inFlight[id] = Task { await self.run(start, ends: ends, hold: hold) }
        case .dictationConfirmed(let mode):
            if let id = capturingID { emit(.confirmed(id, mode)) }
        case .dictationStopped(let at):
            endCapture(.stop(at: at))
        case .dictationCancelled:
            endCapture(.cancel)
        case .dictationDiscarded:
            endCapture(.discard)
        case .pasteLast:
            Task { await self.pasteLast() }
        case .justFixed:
            let access = CloudAccess.granted(by: preferences.snapshot(), app: .unknown, keys: secrets.lookup)
            if let fixes { Task { await fixes.justFixed(access: access) } }
        }
    }

    /// ⌃⌘V: the final text of the newest Dictation that has text, at the current focus.
    /// Same insert path as a live Dictation (target captured now).
    public func pasteLast() async {
        guard let (id, text) = await history.newestText() else { return emit(.notice(.nothingToPaste)) }
        guard let target = await destination.target() else { return emit(.notice(.noFieldToPaste)) }
        switch await destination.insert(text, for: id, at: target) {
        case .inserted(let receipt): history.record(.delivered(id, receipt, lag: nil))
        case .notInserted, .historyOnly: break  // the row keeps its status; Jake can press it again
        }
    }

    /// History's ⋯ > Retry. Never typed: Jake is in the History window.
    /// `model` nil = the normal plan; otherwise the picker's choice.
    public func retry(_ id: DictationID, with model: SpeechModel?) async -> DictationResult {
        fatalError("not implemented")
    }

    /// Launch: transcribe what the last run left unfinished. Never typed.
    /// Safe to call twice (History.recover is idempotent; ids already in flight are skipped).
    public func recover() async {
        fatalError("not implemented")
    }

    /// The dev app's "dictate this WAV" test hook and `lexicon-eval`:
    /// the same run as a live Dictation, audio from a file, stop at end of file.
    /// In the dev app the text is typed into the focused field; headless it is recorded.
    public func dictate(file: URL, pace: FilePace, purpose: DictationPurpose = .type) async -> DictationResult {
        let id = DictationID()
        insertOrder.append(id)
        // Ended by end of file (see `nextEnd`). Held open until the run returns:
        // a finished stream reads as "stop now" and would cut the file short.
        let (ends, open) = AsyncStream<RunEnd>.makeStream()
        defer { open.finish() }
        let start = RunStart(id: id, input: .file(file, pace: pace), preferences: preferences.snapshot(),
                             origin: .file, purpose: purpose, began: .now())
        return await run(start, ends: ends, hold: LatencyHold(reason: "Dictation \(id) from file"))
    }

    /// Lid close or sleep is a normal stop (#4).
    public func systemWillSleep() { endCapture(.stop(at: .now())) }

    /// UI, logs. Each call returns a new stream (any number of observers).
    public func events() -> AsyncStream<ConductorEvent> {
        let (stream, continuation) = AsyncStream<ConductorEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        subscribers[UUID()] = continuation
        return stream
    }

    // MARK: Internals

    /// Suspends until `id` is first in `insertOrder`.
    func insertTurn(_ id: DictationID) async {
        guard insertOrder.contains(id), insertOrder.first != id else { return }
        await withCheckedContinuation { turnWaiters[id] = $0 }
    }

    /// Removes `id` from `insertOrder` (idempotent) and wakes the next in line.
    func releaseInsertTurn(_ id: DictationID) {
        insertOrder.removeAll { $0 == id }
        if let head = insertOrder.first { turnWaiters.removeValue(forKey: head)?.resume() }
    }

    func endCapture(_ end: RunEnd) {
        captureEnd?.yield(end)
        captureEnd?.finish()
        captureEnd = nil
        capturingID = nil
    }

    func emit(_ event: ConductorEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }
}

extension Conductor {
    /// Everything `land` needs about one Dictation past fn-up, as one value, so
    /// live, waiting, retry and recovery hand over the same thing (retry and
    /// recovery build it with `target: nil`, `releasedAt: nil` and their own
    /// `cleaning` from `cleanup.begin(plan:)`).
    struct DictationRun: Sendable {
        let id: DictationID
        let origin: DictationOrigin
        let purpose: DictationPurpose
        let context: AppContext
        /// RAM copy of the audio, for the waiting branch's second transcription.
        let clip: AudioClip
        let speechPlan: SpeechPlan
        let cleanupPlan: CleanupPlan
        var cleaning: CleanupSession
        /// Live: `Preferences.cleanupDeadline` (about 450 ms). Retry and recovery: seconds (nobody waits).
        let cleanupDeadline: Duration
        let access: CloudAccess?
        /// nil: never typed (recovery, retry). No public init exists to make one up.
        let target: Destination.Target?
        var releasedAt: HostTime?
        /// The status before this landing, for `DictationStatus.landed`.
        var previous: DictationStatus?
        let hold: LatencyHold

        /// Jake waits at the cursor only when the text may still be typed.
        var localPriority: LocalPriority { target == nil ? .background : .live }
    }
}

/// Keeps App Nap and timer coalescing from delaying a Dictation: a
/// `.userInitiated, .latencyCritical` activity from fn-down until the text
/// lands. Begins in `Conductor.handle(.dictationBegan)` (and `dictate(file:)`);
/// ends in `land` right after the insert, before a network wait, or when `run`
/// returns, whichever is first. `end` is idempotent.
final class LatencyHold: Sendable {
    private let token: Mutex<(any NSObjectProtocol)?>

    init(reason: String) {
        token = Mutex(ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: reason))
    }

    func end() {
        token.withLock { held in
            if let held { ProcessInfo.processInfo.endActivity(held) }
            held = nil
        }
    }
}

/// How the capture phase of a run ends.
enum RunEnd: Sendable {
    case stop(at: HostTime)
    case cancel
    case discard
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
    /// nil: discarded, or capture never started (nothing was recorded, nothing lost).
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

/// What the UI shows. The ONE list of things the indicator, status item and
/// notices react to; the UI switches over it exhaustively.
public enum ConductorEvent: Sendable {
    case started(DictationID)
    /// First real audio arrived: show "listening" now (#4).
    case listening(DictationID)
    case confirmed(DictationID, DictationMode)
    case transcribing(DictationID)
    case finished(DictationID, DictationStatus)
    case notice(Notice)
}

public enum Notice: Sendable, Hashable {
    /// Text ready but not typed: "Dictation ready, paste-last to insert" (#4).
    case readyToPaste(DictationID)
    case waitingForNetwork(DictationID)
    case microphoneUnavailable(String)
    case microphoneSilent
    case microphoneMuted
    case diskTrouble
    case accessibilityNeeded
    case nothingToPaste
    case noFieldToPaste
}
