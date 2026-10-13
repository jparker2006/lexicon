import CoreGraphics
import Testing
import LexiconDomain
@testable import AppText
@testable import KeyInput

// ⌃⌘V on the tap thread's queue (#62). The tap is never started, so `perform`
// and `send` run inline on the test's thread: the commands come out in the order
// they were called in. The continuation is finished before the stream is read,
// so a `send` that yields nothing fails the test; it never hangs it.

/// A tap never started, with the keyboard built on its stream, as the key tests do.
private struct NeverStartedTap {
    let tap: EventTapThread
    let keyboard: Keyboard
    private let continuation: AsyncStream<KeyCommand>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<KeyCommand>.makeStream()
        tap = Keyboard.tap(KeyboardConfig(), input: InputClock(), continuation: continuation)
        keyboard = Keyboard(tap: tap, commands: stream)
        self.continuation = continuation
    }

    /// Every command yielded, in order, once the stream is finished.
    func commands() async -> [KeyCommand] {
        continuation.finish()
        var commands: [KeyCommand] = []
        for await command in keyboard.commands { commands.append(command) }
        return commands
    }
}

/// Milliseconds after an arbitrary fn-down. Explicit HostTimes, never the wall clock.
private func at(_ milliseconds: Int) -> HostTime {
    HostTime(nanoseconds: 5_000_000_000 + UInt64(milliseconds) * 1_000_000)
}

@Test(.timeLimit(.minutes(1)))
func aPasteLastPressQueuesBehindTheFnCommandsBeforeIt() async {
    let rig = NeverStartedTap()
    let id = DictationID()
    // fn goes down at 0 ms, ⌃⌘V is pressed in the middle of the hold, fn is let go at 1000 ms.
    rig.tap.perform(.fnDown(at(0), secureInput: false, id: id))
    rig.tap.send(.pasteLast)
    rig.tap.perform(.fnUp(at(1_000)))
    let commands = await rig.commands()
    #expect(commands == [
        .dictationBegan(id, at: at(0)),
        .pasteLast,
        .dictationConfirmed(id, .hold),
        .dictationStopped(id, at: at(1_000)),
    ], "⌃⌘V is yielded between the fn-down's and the fn-up's commands, in the order they happened")
}

@Test(.timeLimit(.minutes(1)))
func aPasteLastPressAloneYieldsOnePasteLast() async {
    let rig = NeverStartedTap()
    rig.tap.send(.pasteLast)
    let commands = await rig.commands()
    #expect(commands == [.pasteLast], "one press yields exactly one pasteLast and nothing else")
}

@Test(.timeLimit(.minutes(1)))
func aControlCommandVKeyDownSeenByTheTapNeverPastes() async {
    let rig = NeverStartedTap()
    // The key-down of ⌃⌘V as the tap's own handler sees it, from the hardware (pid 0), not Lexicon.
    let chord = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
    chord.flags = [.maskControl, .maskCommand]
    chord.timestamp = 0
    chord.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    _ = rig.tap.handle(.keyDown, chord)
    rig.tap.perform(.otherKey(at(0)))
    let commands = await rig.commands()
    #expect(!commands.contains(.pasteLast), "the tap sees ⌃⌘V as an ordinary key; only the hotkey pastes")
}

/// A key-down from the keyboard (pid 0), as the tap's own handler sees it, pressed at `at`
/// (an explicit time, so pairing never depends on how long the test takes).
private func keyDown(_ keyCode: CGKeyCode, _ flags: CGEventFlags, at: HostTime = HostTime(nanoseconds: 0)) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
    event.flags = flags
    event.timestamp = at.nanoseconds
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    return event
}

@Test(.timeLimit(.minutes(1)))
func aPasteLastPressNeverHoldsItsOwnPaste() {
    let input = InputClock()
    let t = at(1_000)  // one press time for both of a press's reports
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    // The hotkey's command goes first and the paste takes its mark; only then does the
    // tap's copy of the same ⌃⌘V key-down arrive. It is not typing since the press.
    tap.send(.pasteLast, pressedAt: t)
    let mark = input.mark()
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: t), now: t)
    let field = FocusSnapshot(pid: 42, fieldFingerprint: "field")
    let decision = InsertGuard.decide(target: field, focusNow: field, inputSinceMark: input.hasInput(since: mark),
                                      sinceCapture: .zero)
    #expect(decision == .insert, "the press that asked for the paste is not typing since the press")
}

@Test(.timeLimit(.minutes(1)), arguments: [CGEventFlags(), [.maskCommand], [.maskControl, .maskCommand, .maskShift]])
func everyOtherVKeyDownStillCountsAsTyping(_ flags: CGEventFlags) {
    let input = InputClock()
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    let mark = input.mark()
    _ = tap.handle(.keyDown, keyDown(9, flags))
    #expect(input.hasInput(since: mark), "v, ⌘V and ⌃⇧⌘V are Jake typing; only ⌃⌘V itself is not")
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func aPasteLastPressStillCountsAsTypingForADictationInFlight(tapCopyFirst: Bool) {
    let input = InputClock()
    let t = at(1_000)  // one press time for both of a press's reports
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    // An earlier Dictation took its target at fn-up; then Jake presses ⌃⌘V. Its text,
    // still on the way, must not land after the paste he asked for.
    let fnUp = input.mark()
    if tapCopyFirst { _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: t), now: t) }
    tap.send(.pasteLast, pressedAt: t)
    if !tapCopyFirst { _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: t), now: t) }
    #expect(input.hasInput(since: fnUp), "⌃⌘V is typing since that fn-up")
}

@Test(.timeLimit(.minutes(1)))
func aPasteLastPressCountsAsTypingAtItsFirstReport() {
    let input = InputClock()
    let t = at(1_000)  // one press time for both of a press's reports
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    let fnUp = input.mark()
    // The tap's copy can come before the hotkey's press: the press counts from then on.
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: t), now: t)
    #expect(input.hasInput(since: fnUp), "a Dictation checked between the two reports sees the press")
    // The hotkey's report of the same press is not a second keystroke, and the paste
    // it asks for marks after the press, so the press never holds it.
    let beforeHotkey = input.mark()
    tap.send(.pasteLast, pressedAt: t)
    #expect(!input.hasInput(since: beforeHotkey), "one press is one keystroke")
}

@Test(.timeLimit(.minutes(1)))
func aControlCommandVTheHotkeyNeverSawStillCountsAsTyping() {
    let input = InputClock()
    let t = at(1_000)  // one press time for both of a press's reports
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    // Another app holds ⌃⌘V, so the hotkey never registered: the key reaches the app.
    let fnUp = input.mark()
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: t), now: t)
    #expect(input.hasInput(since: fnUp))
    let afterFirst = input.mark()
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: t), now: t)
    #expect(input.hasInput(since: afterFirst), "each press the hotkey never reported is typing")
}

@Test(.timeLimit(.minutes(1)))
func holdingControlCommandVNeverLetsALaterPressHoldItsOwnPaste() {
    let input = InputClock()
    let t = at(1_000)  // one press time for both of a press's reports
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    // Jake holds ⌃⌘V: one hotkey report, and the key repeats at the tap.
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: t), now: t)
    tap.send(.pasteLast, pressedAt: t)
    for _ in 0..<3 {
        let repeated = keyDown(9, [.maskControl, .maskCommand], at: t)
        repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        _ = tap.handle(.keyDown, repeated)
    }
    // His next press: this time the hotkey's report comes first, the paste marks, then the tap's copy.
    tap.send(.pasteLast, pressedAt: t)
    let mark = input.mark()
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: t), now: t)
    #expect(!input.hasInput(since: mark), "the press counted before its command, not after its paste's mark")
}

@Test(.timeLimit(.minutes(1)))
func aPressWhoseHotkeyReportWasLostNeverPairsWithTheNextPress() {
    let input = InputClock()
    let t = at(1_000)  // one press time for both of a press's reports
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    // Half a second ago a ⌃⌘V reached the tap, and its hotkey report never came.
    let earlier = keyDown(9, [.maskControl, .maskCommand], at: t)
    earlier.timestamp = at(500).nanoseconds
    _ = tap.handle(.keyDown, earlier, now: at(500))
    // Now a new press: the hotkey's report first, the paste marks, then the tap's copy.
    tap.send(.pasteLast, pressedAt: t)
    let mark = input.mark()
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: t), now: t)
    #expect(!input.hasInput(since: mark), "the new press counted before its command, not after its paste's mark")
}

@Test func aHotkeyPressesTwoReportsPairOnlyWhenTheyAreTheSameMoment() {
    var presses = HotkeyPresses()
    let counted = [
        // One press, either order: the first report counts, its partner doesn't.
        presses.isFirstReport(.tapCopy, at: at(0)), presses.isFirstReport(.hotkey, at: at(3)),
        presses.isFirstReport(.hotkey, at: at(1_000)), presses.isFirstReport(.tapCopy, at: at(1_001)),
        // A report whose partner never came is not the partner of a press 600 ms later.
        presses.isFirstReport(.tapCopy, at: at(2_000)), presses.isFirstReport(.hotkey, at: at(2_600)),
        // Two reports of one kind are two presses.
        presses.isFirstReport(.tapCopy, at: at(4_000)), presses.isFirstReport(.tapCopy, at: at(4_100)),
    ]
    #expect(counted == [true, false, true, false, true, true, true, true])
}

@Test(.timeLimit(.minutes(1)))
func twoQuickPressesEachPairWithTheirOwnReports() {
    let input = InputClock()
    let t = at(1_000), first = at(900)
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    // Two presses 100 ms apart; both tap copies reach the tap thread before either hotkey report.
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: first), now: first)
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: t), now: t)
    tap.send(.pasteLast, pressedAt: first)
    let afterFirstCommand = input.mark()
    tap.send(.pasteLast, pressedAt: t)
    #expect(!input.hasInput(since: afterFirstCommand), "two presses are two keystrokes, not three")
}

@Test(.timeLimit(.minutes(1)))
func aHeldControlCommandVStillCountsAsTyping() {
    let input = InputClock()
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    let mark = input.mark()
    let repeated = keyDown(9, [.maskControl, .maskCommand])
    repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    _ = tap.handle(.keyDown, repeated)
    #expect(input.hasInput(since: mark), "a held key's repeats are typing, as for every other key")
}

@Test(.timeLimit(.minutes(1)))
func aLateTapCopyNeverHoldsItsOwnPaste() {
    let input = InputClock()
    let press = at(1_000), late = at(2_200)
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    tap.send(.pasteLast, pressedAt: press)
    let mark = input.mark()
    // A busy Mac: the tap's copy of the same key-down is handled 1.2 s after the press.
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand], at: press), now: late)
    #expect(!input.hasInput(since: mark), "the copy pairs by its own key-down time, however late it is handled")
}
