import CoreGraphics
import Testing
import LexiconDomain
@testable import KeyInput

// What the fn recognizer sees of a real CGEvent (#53). The events are built
// in-process and never posted, so no Accessibility permission is needed.
// Keycodes: fn 63, Shift 56 (left) and 60 (right), Command 55, Option 58, Control 59.

/// A fixed clock reading, about 10 days of uptime.
private let fixedNow = HostTime(nanoseconds: 900_000_000_000_000)

/// Milliseconds after `fixedNow`.
private func at(_ milliseconds: Int) -> HostTime {
    HostTime(nanoseconds: fixedNow.nanoseconds + UInt64(milliseconds) * 1_000_000)
}

/// A key-down or key-up, as the keyboard makes it.
private func keyEvent(_ keyCode: CGKeyCode, down: Bool = true, flags: CGEventFlags = []) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
    event.flags = flags
    event.timestamp = 0  // unstamped, so every reading is `now` unless a test stamps it
    return event
}

/// A modifier change: what the tap sees when fn or Shift goes down or up.
private func flagsChanged(_ keyCode: CGKeyCode, _ flags: CGEventFlags) -> CGEvent {
    let event = keyEvent(keyCode, flags: flags)
    event.type = .flagsChanged
    return event
}

/// Translates one real event, then feeds whatever the recognizer sees of it.
/// An event it ignores feeds nothing.
private func feed(_ event: CGEvent, at now: HostTime, into gesture: inout FnGesture) -> [KeyCommand] {
    guard let key = KeyInput(event, secureInput: { false }, now: now) else { return [] }
    return gesture.handle(key).commands
}

/// fn-down at `at`, whatever Dictation id it minted.
private func isFnDown(_ key: KeyInput?, at: HostTime, secureInput: Bool) -> Bool {
    if case .fnDown(at, secureInput, _)? = key { true } else { false }
}

@Test func fnDownWithoutAPasswordFieldIsFnDown() {
    let now = at(0)
    #expect(isFnDown(KeyInput(flagsChanged(63, [.maskSecondaryFn]), secureInput: { false }, now: now), at: now, secureInput: false))
}

@Test func fnDownInAPasswordFieldIsFnDownWithSecureInput() {
    let now = at(0)
    #expect(isFnDown(KeyInput(flagsChanged(63, [.maskSecondaryFn]), secureInput: { true }, now: now), at: now, secureInput: true))
}

@Test func fnUpIsFnUp() {
    let now = at(0)
    #expect(KeyInput(flagsChanged(63, []), secureInput: { false }, now: now) == KeyInput.fnUp(now))
}

@Test func leftShiftWithFnIsIgnored() {
    #expect(KeyInput(flagsChanged(56, [.maskShift, .maskSecondaryFn]), secureInput: { false }, now: at(0)) == nil)
}

@Test func rightShiftWithFnIsIgnored() {
    #expect(KeyInput(flagsChanged(60, [.maskShift, .maskSecondaryFn]), secureInput: { false }, now: at(0)) == nil)
}

@Test func shiftHeldWhenFnGoesDownIsStillFnDown() {
    let now = at(0)
    #expect(isFnDown(KeyInput(flagsChanged(63, [.maskShift, .maskSecondaryFn]), secureInput: { false }, now: now), at: now, secureInput: false))
}

@Test func fnUpWhileShiftIsStillHeldIsFnUp() {
    let now = at(0)
    #expect(KeyInput(flagsChanged(63, [.maskShift]), secureInput: { false }, now: now) == KeyInput.fnUp(now))
}

@Test func commandOptionAndControlWhileFnIsHeldAreIgnored() {
    let now = at(0)
    #expect(KeyInput(flagsChanged(55, [.maskCommand, .maskSecondaryFn]), secureInput: { false }, now: now) == nil)
    #expect(KeyInput(flagsChanged(58, [.maskAlternate, .maskSecondaryFn]), secureInput: { false }, now: now) == nil)
    #expect(KeyInput(flagsChanged(59, [.maskControl, .maskSecondaryFn]), secureInput: { false }, now: now) == nil)
}

@Test func fnPlusRightArrowIsAnOtherKey() {
    let now = at(0)
    #expect(KeyInput(keyEvent(124, flags: [.maskSecondaryFn]), secureInput: { false }, now: now)
        == KeyInput.otherKey(now))
}

@Test func fnPlusRightArrowArrivesAsEndAndIsAnOtherKey() {
    // The system delivers fn+Right as End, so End must count as a key too.
    let now = at(0)
    #expect(KeyInput(keyEvent(119, flags: [.maskSecondaryFn]), secureInput: { false }, now: now)
        == KeyInput.otherKey(now))
}

@Test func letterKeyIsAnOtherKey() {
    let now = at(0)
    #expect(KeyInput(keyEvent(0), secureInput: { false }, now: now) == KeyInput.otherKey(now))
}

@Test func mouseDownIsIgnored() {
    let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
    #expect(KeyInput(click, secureInput: { false }, now: at(0)) == nil)
}

@Test func keyUpIsIgnored() {
    let release = keyEvent(0, down: false)
    #expect(release.type == .keyUp)
    #expect(KeyInput(release, secureInput: { false }, now: at(0)) == nil)
}

@Test func secureInputIsAskedOnlyOnFnDown() {
    let now = at(0)
    var asked = 0
    _ = KeyInput(flagsChanged(63, [.maskSecondaryFn]), secureInput: { asked += 1; return false }, now: now)
    #expect(asked == 1)
    _ = KeyInput(flagsChanged(63, []), secureInput: { asked += 1; return false }, now: now)
    #expect(asked == 1)
    _ = KeyInput(keyEvent(0), secureInput: { asked += 1; return false }, now: now)
    #expect(asked == 1)
}

@Test func shiftWithFnNeverCancelsAHoldFromTheEvents() throws {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    var commands = feed(flagsChanged(63, [.maskSecondaryFn]), at: at(0), into: &gesture)
    commands += feed(flagsChanged(56, [.maskShift, .maskSecondaryFn]), at: at(50), into: &gesture)
    commands += gesture.handle(.deadline(at(300))).commands
    commands += feed(flagsChanged(63, [.maskShift]), at: at(1_500), into: &gesture)
    let id = try #require(beganID(commands))
    #expect(commands == [.dictationBegan(id, at: at(0)), .dictationConfirmed(id, .hold), .dictationStopped(id, at: at(1_500))])
}

@Test func shiftWithFnThenArrowWithinTheThresholdCancelsTheHold() throws {
    var gesture = FnGesture(holdThreshold: .milliseconds(300))
    var commands = feed(flagsChanged(63, [.maskSecondaryFn]), at: at(0), into: &gesture)
    commands += feed(flagsChanged(56, [.maskShift, .maskSecondaryFn]), at: at(50), into: &gesture)
    commands += feed(keyEvent(124, flags: [.maskShift, .maskSecondaryFn]), at: at(200), into: &gesture)
    commands += feed(flagsChanged(63, [.maskShift]), at: at(1_500), into: &gesture)
    let id = try #require(beganID(commands))
    #expect(commands == [.dictationBegan(id, at: at(0)), .dictationDiscarded(id)])
}

/// The id the first fn-down minted.
private func beganID(_ commands: [KeyCommand]) -> DictationID? {
    if case .dictationBegan(let id, _)? = commands.first { id } else { nil }
}

@Test func unstampedEventIsTakenAsNow() {
    #expect(HostTime(eventTimestamp: 0, now: fixedNow) == fixedNow)
}

@Test func nanosecondStampTwoMillisecondsAgoIsThatTime() {
    let twoMillisecondsAgo = fixedNow.nanoseconds - 2_000_000
    #expect(HostTime(eventTimestamp: twoMillisecondsAgo, now: fixedNow)
        == HostTime(nanoseconds: twoMillisecondsAgo))
}

@Test func futureStampIsTakenAsNow() {
    #expect(HostTime(eventTimestamp: fixedNow.nanoseconds + 1_000_000, now: fixedNow) == fixedNow)
}

@Test func stampFiveSecondsOldIsTakenAsNow() {
    #expect(HostTime(eventTimestamp: fixedNow.nanoseconds - 5_000_000_000, now: fixedNow) == fixedNow)
}

@Test func theEventsOwnTimeIsUsedNotWhenItWasDelivered() {
    // fn-up stamped 200 ms before the tap saw it: judged at its own time, so a
    // lone tap delivered late is still a tap.
    let up = flagsChanged(63, [])
    up.timestamp = fixedNow.nanoseconds - 200_000_000
    #expect(KeyInput(up, secureInput: { false }, now: fixedNow)
        == .fnUp(HostTime(nanoseconds: fixedNow.nanoseconds - 200_000_000)))
}

@Test func onlyKeyDownsAndClicksCountAsTyping() {
    #expect(EventTapThread.isTypingOrClicking(.keyDown))
    #expect(EventTapThread.isTypingOrClicking(.leftMouseDown))
    #expect(EventTapThread.isTypingOrClicking(.rightMouseDown))
    #expect(EventTapThread.isTypingOrClicking(.otherMouseDown))
    #expect(!EventTapThread.isTypingOrClicking(.flagsChanged))  // fn-up is not "typed since fn-up"
}

@Test func inputClockSeesInputSinceAMark() {
    let clock = InputClock()
    let mark = clock.mark()
    #expect(!clock.hasInput(since: mark))
    clock.tick()
    #expect(clock.hasInput(since: mark))
    #expect(!clock.hasInput(since: clock.mark()))
}

@Test func noListenAccessStartsNoTapAndSaysWhy() {
    // The daily app's grants can differ from Lexicon Dev's: without listen access
    // the tap is never created (so no Input Monitoring prompt), and the error says why.
    #expect(throws: KeyboardError.noListenAccess) {
        try Keyboard.start(KeyboardConfig(), input: InputClock(), listenAccess: false)
    }
}
