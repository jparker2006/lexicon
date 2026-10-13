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

/// A key-down from the keyboard (pid 0), as the tap's own handler sees it.
private func keyDown(_ keyCode: CGKeyCode, _ flags: CGEventFlags) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
    event.flags = flags
    event.timestamp = 0
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    return event
}

@Test(.timeLimit(.minutes(1)))
func aPasteLastPressNeverHoldsItsOwnPaste() {
    let input = InputClock()
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    // The hotkey's command goes first and the paste takes its mark; only then does the
    // tap's copy of the same ⌃⌘V key-down arrive. It is not typing since the press.
    tap.send(.pasteLast)
    let mark = input.mark()
    _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand]))
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
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = Keyboard.tap(KeyboardConfig(), input: input, continuation: continuation)
    // An earlier Dictation took its target at fn-up; then Jake presses ⌃⌘V. Its text,
    // still on the way, must not land after the paste he asked for.
    let fnUp = input.mark()
    if tapCopyFirst { _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand])) }
    tap.send(.pasteLast)
    if !tapCopyFirst { _ = tap.handle(.keyDown, keyDown(9, [.maskControl, .maskCommand])) }
    #expect(input.hasInput(since: fnUp), "⌃⌘V is typing since that fn-up")
}
