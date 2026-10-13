import CoreGraphics
import Testing
import LexiconDomain
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
        tap = EventTapThread(gesture: FnGesture(holdThreshold: .milliseconds(300)), input: InputClock(),
                             continuation: continuation)
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
