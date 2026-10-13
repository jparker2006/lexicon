import Foundation
import Testing
@testable import AudioCapture
@testable import LexiconCore
import AppText
import Cleanup
import History
import LexiconDomain
import Transcription
import WordStore

// Quit waits for the last paste's clipboard restore (#132). A Dictation started while
// it waits is waited for too: fn pressed in that window must not be cut by the exit.
// Headless: the real Conductor on a fake mic, a destination whose clipboard wait is gated.

/// Inserts every Dictation, and holds its first `finishClipboard` until `release()`.
private actor GatedClipboard: TextDestination {
    struct Target: Sendable {}
    private(set) var finishCalls = 0
    private var quitReturned = false
    private var held = true
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var gate: [CheckedContinuation<Void, Never>] = []

    func context() -> AppContext { .unknown }
    func appChanges() -> AsyncStream<AppContext> { AsyncStream { $0.yield(.unknown) } }
    func target() -> Target? { Target() }
    func insert(_ text: String, for id: DictationID, at target: Target) -> Delivery {
        .inserted(InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "f", caretAfter: 0,
                                   contextBefore: "", contextAfter: "", insertedAt: Date()))
    }

    func finishClipboard() async {
        finishCalls += 1
        for waiter in entered { waiter.resume() }
        entered = []
        if held { await withCheckedContinuation { gate.append($0) } }
    }

    /// Returns once the Conductor is waiting on the clipboard, or once Quit returned without it.
    func waitForFinish() async {
        if finishCalls > 0 || quitReturned { return }
        await withCheckedContinuation { entered.append($0) }
    }

    func quitDidReturn() {
        quitReturned = true
        for waiter in entered { waiter.resume() }
        entered = []
    }

    func release() {
        held = false
        for waiter in gate { waiter.resume() }
        gate = []
    }
}

/// fn-down two seconds before now, so every fn event is in the past when the Conductor reads it.
private let fnZero = HostTime(nanoseconds: HostTime.now().nanoseconds - 2_000_000_000)

private func fnAt(_ milliseconds: Int) -> HostTime {
    HostTime(nanoseconds: fnZero.nanoseconds + UInt64(milliseconds) * 1_000_000)
}

@Test(.timeLimit(.minutes(1)))
func aDictationStartedWhileQuitWaitsForTheClipboardIsWaitedFor() async throws {
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let destination = GatedClipboard()
    let recorder = Recorder(hardware: FakeMic().hardware)
    let conductor = Conductor(
        recorder: recorder, speech: SpeechEngine(local: ScriptedTranscriber(text: "Ship it."), clock: TestClock()),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history, destination: destination,
        preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
        keyboard: nil, fixes: nil, jev: nil)
    var events = await conductor.events().makeAsyncIterator()

    let quitting = Task {
        await conductor.idle()
        await destination.quitDidReturn()
    }
    await destination.waitForFinish()  // nothing in flight: Quit is on the clipboard wait
    try #require(await destination.finishCalls == 1, "Quit waits for the clipboard as part of idle")

    let id = DictationID()
    await conductor.handle(.dictationBegan(id, at: fnAt(0)))
    while let event = await events.next() {
        if case .started(id) = event { break }
    }
    await conductor.handle(.dictationConfirmed(id, .hold))
    await conductor.handle(.dictationStopped(id, at: fnAt(600)))
    await destination.release()
    await quitting.value

    // Quit returned only after the Dictation fn started meanwhile had landed.
    #expect(await history.dictation(id)?.status == .inserted)
}
