import Foundation
import Testing
@testable import AudioCapture
@testable import KeyInput
@testable import LexiconCore
import AppText
import Cleanup
import History
import LexiconDomain
import LexiconUI
import Transcription
import WordStore

// Paste-last prepares the held hotkey before taking the focus and InputClock mark.
// The synthetic wait drives the real guard and clock without keys, sleeps, or a live app.
private let preparationSpeech = "Please rename the fetchUser hook."
private let preparationFocus = FocusSnapshot(pid: 42, fieldFingerprint: nil)

private actor PreparationDestination: TextDestination {
    struct Target: Sendable {
        let mark: InputMark
        let capturedAt: Duration
        let focus: FocusSnapshot
    }

    private let input = InputClock()
    private let queuedFor: Duration
    private let autorepeatsDuringWait: Bool
    private var virtualNow: Duration = .zero
    private var prepared = false
    private(set) var calls: [String] = []
    private(set) var pasteDecision: InsertDecision?

    init(queuedFor: Duration = .zero, autorepeatsDuringWait: Bool = true) {
        self.queuedFor = queuedFor
        self.autorepeatsDuringWait = autorepeatsDuringWait
    }

    func context() -> AppContext { .unknown }
    func appChanges() -> AsyncStream<AppContext> { AsyncStream { $0.yield(.unknown) } }

    // The simulated key repeat and wait finish before target().
    func prepareForPasteLast() async {
        calls.append("prepare")
        advanceThroughKeyWait()
        prepared = true
    }

    func target() -> Target? {
        calls.append("target")
        return Target(mark: input.mark(), capturedAt: virtualNow - queuedFor, focus: preparationFocus)
    }

    func insert(_ text: String, for id: DictationID, at target: Target) -> Delivery {
        .notInserted(.focusMoved)
    }

    func pasteLast(_ text: String, for id: DictationID, at target: Target) -> Delivery {
        calls.append("paste")
        // On the old call order, the wait happened here, after the target's mark and time.
        if !prepared { advanceThroughKeyWait() }
        let decision = InsertGuard.decide(target: target.focus, focusNow: target.focus,
                                          inputSinceMark: input.hasInput(since: target.mark),
                                          sinceCapture: virtualNow - target.capturedAt)
        pasteDecision = decision
        switch decision {
        case .insert:
            return .inserted(InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "paste",
                                              caretAfter: text.utf16.count, contextBefore: "", contextAfter: "",
                                              insertedAt: Date()))
        case .hold(let reason):
            return .notInserted(reason)
        }
    }

    func clearPasteTrace() { calls = []; pasteDecision = nil }

    private func advanceThroughKeyWait() {
        virtualNow += .seconds(1)
        if autorepeatsDuringWait { input.tick() }
    }
}

private func preparationConductor(_ destination: PreparationDestination) throws -> (Conductor<PreparationDestination>, HistoryStore) {
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let conductor = Conductor(
        recorder: Recorder(), speech: SpeechEngine(local: ScriptedTranscriber(text: preparationSpeech), clock: TestClock()),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history, destination: destination,
        preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
        keyboard: nil, fixes: nil, jev: nil)
    return (conductor, history)
}

private func seedPasteLast(_ conductor: Conductor<PreparationDestination>, history: HistoryStore,
                           destination: PreparationDestination) async throws {
    let wav = try writeWAV(syntheticSamples(count: 19_200), rate: 16_000, in: try scratchDirectory())
    let result = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    await history.flush()
    #expect(result.status == .notInserted)
    await destination.clearPasteTrace()
}

@Test(.timeLimit(.minutes(1)))
func pasteLastAutorepeatDuringKeyReleaseWaitIsBeforeItsInputMark() async throws {
    let destination = PreparationDestination(autorepeatsDuringWait: true)
    let (conductor, history) = try preparationConductor(destination)
    try await seedPasteLast(conductor, history: history, destination: destination)

    await conductor.pasteLast()

    #expect(await destination.pasteDecision == .insert,
            "the held hotkey's autorepeat happens before the target mark, so it cannot hold its own paste")
    #expect(await destination.calls == ["prepare", "target", "paste"],
            "paste-last releases its hotkey before capturing the target")
}

@Test(.timeLimit(.minutes(1)))
func pasteLastWaitDoesNotSpendTheFieldlessGuardWindow() async throws {
    let recentDestination = PreparationDestination(queuedFor: .milliseconds(4_500), autorepeatsDuringWait: false)
    let (recentConductor, recentHistory) = try preparationConductor(recentDestination)
    try await seedPasteLast(recentConductor, history: recentHistory, destination: recentDestination)
    await recentConductor.pasteLast()
    #expect(await recentDestination.pasteDecision == .insert,
            "a 4.5 second queued paste remains inside the five second fieldless window after key release")

    let expiredDestination = PreparationDestination(queuedFor: .seconds(5), autorepeatsDuringWait: false)
    let (expiredConductor, expiredHistory) = try preparationConductor(expiredDestination)
    try await seedPasteLast(expiredConductor, history: expiredHistory, destination: expiredDestination)
    await expiredConductor.pasteLast()
    #expect(await expiredDestination.pasteDecision == .hold(.tooLate),
            "a paste already five seconds old is still held by the real fieldless guard")
}
