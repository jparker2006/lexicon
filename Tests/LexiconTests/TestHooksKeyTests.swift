#if DEBUG
import CoreGraphics
import Foundation
import Testing
@testable import AudioCapture
@testable import KeyInput
@testable import LexiconCore
import Cleanup
import History
import LexiconDomain
import Transcription
import WordStore

// The fn, Esc and sleep test hooks (#156), headless: a hooked key goes through
// the fn tap's own handler into the real recognizer and the real Conductor, on
// a fake mic and a scripted model. The tap is never started, so it handles each
// key on the test's thread and needs no Accessibility.

@Test(.timeLimit(.minutes(1)))
func aHookedFnPressThroughTheTapTypesADictation() async throws {
    let rig = try HookRig()
    var events = await rig.conductor.events().makeAsyncIterator()

    rig.keyboard.press(.fnDown(shift: false))
    rig.keyboard.press(.fnUp(shift: false))
    let seen = await rig.until(\.isFinished, in: &events)
    let id = try #require(seen.compactMap(\.startedID).first)
    await rig.settle()

    #expect(seen.contains { $0.finishedStatus == .inserted })
    #expect(try #require(await rig.history.dictation(id)).status == .inserted)
    #expect(await rig.destination.delivered[id] != nil)
}

@Test(.timeLimit(.minutes(1)))
func aHookedSleepMidPressLandsTheDictationAsANormalStop() async throws {
    let rig = try HookRig()
    var events = await rig.conductor.events().makeAsyncIterator()

    rig.keyboard.press(.fnDown(shift: false))
    let started = await rig.until(\.isStarted, in: &events)
    let id = try #require(started.compactMap(\.startedID).first)
    // What the app's will-sleep observer and `hook sleep` both call.
    await rig.conductor.systemWillSleep()
    let seen = await rig.until(\.isFinished, in: &events)
    await rig.settle()

    #expect(seen.contains { $0.finishedStatus == .inserted })
    #expect(try #require(await rig.history.dictation(id)).status == .inserted)
}

/// Each hooked key, fed to a fresh tap, does what the same key from the
/// keyboard does: the same commands from the recognizer and the same answer to
/// "typed since". After an fn press (unless the key is one), so a key that
/// cancels or stops shows it.
@Test(arguments: [SyntheticKey.fnDown(shift: false), .fnDown(shift: true), .fnUp(shift: false), .fnUp(shift: true),
                  .escape])
func aHookedKeyIsTheKeyboardsKey(_ key: SyntheticKey) async {
    let hooked = await afterAPress(key) { tap in tap.press(key) }
    let real = await afterAPress(key) { tap in
        let event = keyboardEvent(key)
        _ = tap.handle(event.type, event)
    }
    #expect(hooked.commands == real.commands)
    #expect(hooked.typed == real.typed)
    #expect(!real.commands.isEmpty)
}

/// The event as a keyboard sends it, built here by hand rather than by `SyntheticKey`.
private func keyboardEvent(_ key: SyntheticKey) -> CGEvent {
    let (code, down, flags): (CGKeyCode, Bool, CGEventFlags) = switch key {
    case .fnDown(let shift): (63, true, shift ? [.maskSecondaryFn, .maskShift] : [.maskSecondaryFn])
    case .fnUp(let shift): (63, false, shift ? [.maskShift] : [])
    case .escape: (53, true, [])
    }
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
    if code == 63 { event.type = .flagsChanged }
    event.flags = flags
    event.timestamp = 0
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)  // the hardware, not Lexicon
    return event
}

/// A fresh tap, fn pressed first unless `key` is a press, then `key` by
/// `deliver`: the recognizer's commands (ids dropped) and whether `key` counted as typing.
private func afterAPress(_ key: SyntheticKey, _ deliver: (EventTapThread) -> Void) async
    -> (commands: [String], typed: Bool)
{
    let input = InputClock()
    let (stream, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = EventTapThread(gesture: FnGesture(KeyboardConfig(holdThreshold: .seconds(60))), input: input,
                             continuation: continuation, secureInput: { false })
    if case .fnDown = key {} else { _ = tap.handle(.flagsChanged, keyboardEvent(.fnDown(shift: false))) }
    let mark = input.mark()
    deliver(tap)
    continuation.finish()
    var commands: [String] = []
    for await command in stream { commands.append(command.kind) }
    return (commands, input.hasInput(since: mark))
}

extension KeyCommand {
    /// The command without its Dictation id, so two presses can be compared.
    var kind: String {
        switch self {
        case .dictationBegan: "began"
        case .dictationConfirmed(_, let mode): "confirmed \(mode)"
        case .dictationStopped: "stopped"
        case .dictationCancelled: "cancelled"
        case .dictationDiscarded: "discarded"
        case .oneMinuteLeft: "oneMinuteLeft"
        case .pasteLast: "pasteLast"
        case .justFixed: "justFixed"
        }
    }
}

/// The real Conductor behind a keyboard whose tap is never started, on a fake
/// mic, a scripted model and a recording destination, with History under a
/// throwaway folder. A zero hold threshold makes every press a hold, whatever
/// the machine's speed.
struct HookRig {
    let keyboard: Keyboard
    let recorder: Recorder
    let history: HistoryStore
    let destination: HeadlessDestination
    let conductor: Conductor<HeadlessDestination>
    private let commands: AsyncStream<KeyCommand>.Continuation

    init(local: any LocalTranscriber = ScriptedTranscriber(text: "Ship it"),
         hardware: MicHardware = FakeMic().hardware) throws {
        let paths = AppPaths.temporary()
        let (stream, continuation) = AsyncStream<KeyCommand>.makeStream()
        let tap = EventTapThread(gesture: FnGesture(KeyboardConfig(holdThreshold: .zero)), input: InputClock(),
                                 continuation: continuation, secureInput: { false })
        keyboard = Keyboard(tap: tap, commands: stream)
        commands = continuation
        recorder = Recorder(hardware: hardware)
        history = try HistoryStore(paths: paths)
        destination = HeadlessDestination()
        let conductor = Conductor(
            recorder: recorder, speech: SpeechEngine(local: local), cleanup: Cleanup(),
            lexicon: try Lexicon(paths: paths), history: history, destination: destination,
            preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
            keyboard: keyboard, fixes: nil, jev: nil)
        self.conductor = conductor
        Task { await conductor.follow(stream) }
    }

    /// Events up to and including the first that matches.
    func until(_ match: (ConductorEvent) -> Bool, in events: inout AsyncStream<ConductorEvent>.Iterator) async
        -> [ConductorEvent]
    {
        var seen: [ConductorEvent] = []
        while let event = await events.next() {
            seen.append(event)
            if match(event) { break }
        }
        return seen
    }

    /// The key loop ended, every Dictation run returned, its audio closed, and History caught up.
    func settle() async {
        commands.finish()
        for run in await conductor.inFlight.values { _ = await run.value }
        await recorder.settle()
        await history.flush()
    }
}

extension ConductorEvent {
    var startedID: DictationID? { if case .started(let id) = self { id } else { nil } }
    var isStarted: Bool { startedID != nil }
    var finishedStatus: DictationStatus? { if case .finished(_, let status) = self { status } else { nil } }
    var isFinished: Bool { finishedStatus != nil }
}
#endif
