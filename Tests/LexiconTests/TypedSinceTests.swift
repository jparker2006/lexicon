import CoreGraphics
import Foundation
import Testing
import LexiconDomain
import AppText
@testable import KeyInput

// "Typed since fn-up" through the real tap callback and the late-text guard
// (#141). The events are built in-process and handed to the tap's handler, never
// posted, so no Accessibility permission is needed.

private let keyboard: Int64 = 0  // a key or click from the hardware itself
private let lexicon = Int64(getpid())
private let otherLexicon = lexicon + 1  // another copy of Lexicon, also answering fn

private func key(_ keyCode: CGKeyCode, flags: CGEventFlags = [], from pid: Int64) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
    event.flags = flags
    event.timestamp = 0
    event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
    return event
}

private func modifier(_ keyCode: CGKeyCode, _ flags: CGEventFlags, from pid: Int64) -> CGEvent {
    let event = key(keyCode, flags: flags, from: pid)
    event.type = .flagsChanged
    return event
}

private func click(from pid: Int64) -> CGEvent {
    let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero,
                        mouseButton: .left)!
    event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
    return event
}

/// The same field at fn-up and at the paste, so only typing can hold the text.
private let field = FocusSnapshot(pid: 42, fieldFingerprint: "field")

/// One held fn press through the tap, with whatever arrives between the press
/// and the paste. Returns the guard's decision at the paste.
private func dictation(between events: [CGEvent]) async -> InsertDecision {
    let input = InputClock()
    let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
    // A zero threshold makes every press a hold, whatever the machine's speed.
    let tap = EventTapThread(gesture: FnGesture(holdThreshold: .zero), input: input, continuation: continuation)
    _ = tap.handle(.flagsChanged, modifier(63, .maskSecondaryFn, from: keyboard))
    // Stricter than the app, which marks once the stop comes out after fn-up.
    let mark = input.mark()
    _ = tap.handle(.flagsChanged, modifier(63, [], from: keyboard))
    for event in events { _ = tap.handle(event.type, event) }
    continuation.finish()
    var stopped = false
    for await command in commands { if case .dictationStopped = command { stopped = true } }
    #expect(stopped, "the press was a hold")
    return InsertGuard.decide(target: field, focusNow: field, inputSinceMark: input.hasInput(since: mark))
}

/// Cmd-V as `PasteKey.Chord` sends it: the V key down with Command set outright.
private func paste(from pid: Int64) -> CGEvent { key(9, flags: .maskCommand, from: pid) }

@Test func fnReleaseAndLexiconsOwnPasteAreNotTypedSince() async {
    // Lexicon's Cmd-V, plus a Command flag change in case macOS reports one for it.
    let own = [modifier(55, .maskCommand, from: lexicon), paste(from: lexicon), modifier(55, [], from: lexicon)]
    #expect(await dictation(between: []) == .insert)
    #expect(await dictation(between: own) == .insert)
}

@Test func jakesKeysAndClicksAfterFnUpAreTypedSince() async {
    #expect(await dictation(between: [key(0, from: keyboard)]) == .hold(.typedSince))
    #expect(await dictation(between: [click(from: keyboard)]) == .hold(.typedSince))
    #expect(await dictation(between: [paste(from: keyboard)]) == .hold(.typedSince))
}

@Test func anotherLexiconsPasteIsTypedSinceSoTheTextIsNotTypedTwice() async {
    // The daily app and Lexicon Dev both answer one fn press: whichever pastes
    // second sees the first one's Cmd-V and holds its copy for paste-last.
    #expect(await dictation(between: [paste(from: otherLexicon)]) == .hold(.typedSince))
}
