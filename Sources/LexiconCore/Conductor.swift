public import Foundation
import os
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
    /// Dictations past stop that still need text (transcribing), and recovered ones being transcribed.
    var inFlight: [DictationID: Task<DictationResult, Never>] = [:]
    /// The `inFlight` entries that are launch recovery, not a live or file Dictation.
    var recovering: Set<DictationID> = []
    /// `idle` waiting for the recording Dictation's capture to end.
    var captureEndWaiters: [CheckedContinuation<Void, Never>] = []
    /// Waiting Dictations, each trying again until it has text (`retryWhenReady`).
    var waiting: [DictationID: Task<Void, Never>] = [:]
    /// Live Dictations in fn-down order. A Dictation inserts only when every
    /// earlier one has inserted, been held, or gone waiting (#18: they insert in
    /// the order they were spoken). A waiting Dictation gives up its turn, so a
    /// network outage never blocks later text; its late text waits for paste-last.
    var insertOrder: [DictationID] = []
    /// A Dictation whose text is ready while an earlier one still holds the turn.
    var turnWaiters: [DictationID: CheckedContinuation<Void, Never>] = [:]
    var subscribers: [UUID: AsyncStream<ConductorEvent>.Continuation] = [:]
    /// One line per Dictation (lag, engine, first audio) and anything dropped:
    /// `log stream --predicate 'subsystem == "Lexicon" && category == "dictation"'`.
    let log = Logger(subsystem: "Lexicon", category: "dictation")

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

    /// The key loop: every command from the fn tap, in order, for the life of the
    /// app (`LexiconSystem.run` passes `Keyboard.commands`). One consumer, one
    /// actor hop per command, so fn-down and fn-up are never reordered.
    public func follow(_ commands: AsyncStream<KeyCommand>) async {
        for await command in commands { handle(command) }
    }

    /// Every key command, one exhaustive switch.
    public func handle(_ command: KeyCommand) {
        switch command {
        case .dictationBegan(let id, let at):
            // fn never waits (#18): an earlier Dictation still finishing is fine; one
            // still in its 200 ms tail has its tail cut by `recorder.start`.
            // The recognizer sends a press's stop or discard before the next press's
            // begin, so this never happens. If it ever does, the newer press is
            // dropped, never the recording one, and it leaves a line in the log.
            guard captureEnd == nil else {
                return log.error("fn-down \(id, privacy: .public) dropped: \(self.capturingID?.description ?? "?", privacy: .public) is still recording")
            }
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
        case .dictationConfirmed(let id, let mode):
            if id == capturingID { emit(.confirmed(id, mode)) }
        case .dictationStopped(let id, let at):
            endCapture(id, .stop(at: at))
        case .dictationCancelled(let id):
            endCapture(id, .cancel)
        case .dictationDiscarded(let id):
            endCapture(id, .discard)
        case .pasteLast:
            Task { await self.pasteLast() }
        case .justFixed:
            // The fix is in the frontmost app, so the always-private list applies to it.
            if let fixes {
                Task {
                    let app = await destination.context()
                    await fixes.justFixed(access: CloudAccess.granted(by: preferences.snapshot(), for: .app(app),
                                                                      keys: secrets.lookup))
                }
            }
        }
    }

    /// ⌃⌘V: the final text of the newest Dictation that has text, at the current focus.
    /// Same insert path as a live Dictation (target captured now).
    public func pasteLast() async {
        guard let (id, text) = await history.newestText() else { return emit(.notice(.nothingToPaste)) }
        guard let target = await destination.target() else { return emit(.notice(.noFieldToPaste)) }
        switch await destination.pasteLast(text, for: id, at: target) {
        case .inserted(let receipt): history.record(.delivered(id, receipt, lag: nil))
        case .notInserted, .historyOnly: break  // the row keeps its status; Jake can press it again
        }
    }

    /// History's ⋯ > Retry. Never typed: Jake is in the History window.
    /// `model` nil = the normal plan; otherwise the picker's choice.
    public func retry(_ id: DictationID, with model: SpeechModel?) async -> DictationResult {
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

    /// Lid close or sleep is a normal stop (#4). A key-owned recording is stopped
    /// by its own press, through the key stream, behind any command already there.
    public func systemWillSleep() {
        if let keyboard { return keyboard.systemWillSleep() }
        if let id = capturingID { endCapture(id, .stop(at: .now())) }
    }

    /// Quit: returns once no Dictation is recording or finishing, and History and
    /// the audio files have everything. A recording Dictation ends the normal way,
    /// at its fn-up, so an install never cuts one (`scripts/lib/install-app.sh` waits).
    /// Dictations past fn-up get `limit` to land: one stuck in the model must not
    /// hold Quit forever, and its row stays for launch recovery. Launch recovery
    /// and waiting Dictations are not waited for: their text is never typed, and
    /// the next launch picks them up again.
    public func idle(finishingWithin limit: Duration = .seconds(30)) async {
        while true {
            if capturingID != nil {
                await withCheckedContinuation { captureEndWaiters.append($0) }
                continue
            }
            let finishing = inFlight.filter { !recovering.contains($0.key) }
            let (landed, land) = AsyncStream<Void>.makeStream()
            let waiting = Task {
                for run in finishing.values { _ = await run.value }
                land.finish()
            }
            let deadline = Task {
                try? await Task.sleep(for: limit)
                land.finish()
            }
            for await _ in landed {}
            waiting.cancel()
            deadline.cancel()
            await history.flush()
            await recorder.settle()
            // Done unless fn went down meanwhile: that Dictation gets the same wait.
            let started = inFlight.keys.filter { !recovering.contains($0) && finishing[$0] == nil }
            if capturingID == nil, started.isEmpty { return }
        }
    }

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

    /// Ends `id`'s capture. A command for any other Dictation (one whose capture
    /// already ended, or that never started) changes nothing.
    func endCapture(_ id: DictationID, _ end: RunEnd) {
        guard id == capturingID else { return }
        // The stop sound marks fn-up itself, not the end of the adaptive tail after it.
        if end.isStop { emit(.stopped(id)) }
        captureEnd?.yield(end)
        captureEnd?.finish()
        captureEnd = nil
        capturingID = nil
        for waiter in captureEndWaiters { waiter.resume() }
        captureEndWaiters = []
    }

    func emit(_ event: ConductorEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }
}

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

/// What the UI shows. The ONE list of things the indicator, status item and
/// notices react to; the UI switches over it exhaustively.
public enum ConductorEvent: Sendable {
    case started(DictationID)
    /// First real audio arrived: show "listening" now (#4).
    case listening(DictationID)
    case confirmed(DictationID, DictationMode)
    /// The 19-minute mark: one minute until the cap stops the Dictation. (#58 emits it.)
    case oneMinuteLeft(DictationID)
    /// fn-up, Esc or sleep ended the recording. Not sent for a discarded tap, which was never confirmed.
    case stopped(DictationID)
    case transcribing(DictationID)
    case finished(DictationID, DictationStatus)
    case notice(Notice)
}

public enum Notice: Sendable, Hashable {
    /// Text ready but not typed: "Dictation ready, paste-last to insert" (#4).
    case readyToPaste(DictationID)
    case waitingForNetwork(DictationID)
    /// A Dictation the last run left unfinished has its text, at the top of History, never typed (#4).
    case recovered(DictationID)
    case microphoneUnavailable(String)
    case microphoneSilent
    case microphoneMuted
    case diskTrouble
    case accessibilityNeeded
    case nothingToPaste
    case noFieldToPaste
}
