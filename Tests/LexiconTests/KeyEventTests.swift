import CoreGraphics
import Synchronization
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
    var gesture = FnGesture(KeyboardConfig(holdThreshold: .milliseconds(300)))
    var commands = feed(flagsChanged(63, [.maskSecondaryFn]), at: at(0), into: &gesture)
    commands += feed(flagsChanged(56, [.maskShift, .maskSecondaryFn]), at: at(50), into: &gesture)
    commands += gesture.handle(.deadline(at(300))).commands
    commands += feed(flagsChanged(63, [.maskShift]), at: at(1_500), into: &gesture)
    let id = try #require(beganID(commands))
    #expect(commands == [.dictationBegan(id, at: at(0)), .dictationConfirmed(id, .hold), .dictationStopped(id, at: at(1_500))])
}

@Test func shiftWithFnThenArrowWithinTheThresholdCancelsTheHold() throws {
    var gesture = FnGesture(KeyboardConfig(holdThreshold: .milliseconds(300)))
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

@Test func stampFiveSecondsOldIsThatTime() {
    // Five seconds old is still the key's own time: a long hold is judged on its stamps,
    // not on the moment the tap happened to read them.
    #expect(HostTime(eventTimestamp: fixedNow.nanoseconds - 5_000_000_000, now: fixedNow)
        == HostTime(nanoseconds: fixedNow.nanoseconds - 5_000_000_000))
}

@Test func theEventsOwnTimeIsUsedNotWhenItWasDelivered() {
    // fn-up stamped 200 ms before the tap saw it: judged at its own time, so a
    // lone tap delivered late is still a tap.
    let up = flagsChanged(63, [])
    up.timestamp = fixedNow.nanoseconds - 200_000_000
    #expect(KeyInput(up, secureInput: { false }, now: fixedNow)
        == .fnUp(HostTime(nanoseconds: fixedNow.nanoseconds - 200_000_000)))
}

@Test func aHoldStampedOverASecondAgoIsConfirmedAndStops() throws {
    // A press held 0.5 s, its events stamped 3 s and 2.5 s before the read. Read as "now",
    // the hold would look like a lone tap, and the Dictation would be discarded instead.
    var gesture = FnGesture(KeyboardConfig(holdThreshold: .milliseconds(300)))
    let down = flagsChanged(63, [.maskSecondaryFn])
    down.timestamp = fixedNow.nanoseconds - 3_000_000_000
    let up = flagsChanged(63, [])
    up.timestamp = fixedNow.nanoseconds - 2_500_000_000
    var commands = feed(down, at: fixedNow, into: &gesture)
    commands += feed(up, at: fixedNow, into: &gesture)
    commands += gesture.handle(.deadline(at(400))).commands  // past a lone tap's window and its grace: a discard would show here
    let id = try #require(beganID(commands))
    #expect(commands.contains(.dictationConfirmed(id, .hold)))
    #expect(stops(id, in: commands))
    #expect(!commands.contains(.dictationDiscarded(id)))
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

@Test func plainEscIsEscapeAndEscWithAModifierIsAnotherKey() {
    let now = at(0)
    // fn may be down (a hold): still plain Esc. Cmd, Option, Control or Shift make it a shortcut.
    #expect(KeyInput(keyEvent(53), secureInput: { false }, now: now) == .escape(now))
    #expect(KeyInput(keyEvent(53, flags: [.maskSecondaryFn]), secureInput: { false }, now: now) == .escape(now))
    for modifier: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift] {
        #expect(KeyInput(keyEvent(53, flags: modifier), secureInput: { false }, now: now) == .otherKey(now))
    }
}

@Test func theTapAsksForEscExactlyWhileADictationIsConfirmed() {
    // The Esc hotkey follows the recognizer: taken when the hold is confirmed, given back when
    // it ends, and asked for only on a change.
    let asked = Mutex<[Bool]>([])
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = EventTapThread(gesture: FnGesture(KeyboardConfig(holdThreshold: .zero)), input: InputClock(),
                             continuation: continuation, secureInput: { false },
                             takeEscape: { on in asked.withLock { $0.append(on) } })
    /// As the keyboard sends it (pid 0): the tap drops events this process posted, its own Cmd-V.
    func fromKeyboard(_ event: CGEvent) -> CGEvent {
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }
    _ = tap.handle(.flagsChanged, fromKeyboard(flagsChanged(63, [.maskSecondaryFn])))
    _ = tap.handle(.keyDown, fromKeyboard(keyEvent(0)))  // a key after the (zero) threshold confirms the hold
    _ = tap.handle(.keyDown, fromKeyboard(keyEvent(1)))
    _ = tap.handle(.keyDown, fromKeyboard(keyEvent(53)))  // Esc cancels
    _ = tap.handle(.keyDown, fromKeyboard(keyEvent(53)))  // a second report of it changes nothing
    #expect(asked.withLock { $0 } == [true, false])
}

@Test func aHotkeyPressIsStampedWithItsOwnEventTime() {
    // Carbon's event time is seconds on the same uptime clock: the hotkey's Esc keeps the time it
    // was pressed, not when thread hops later the recognizer gets it, however late that is, so a
    // late copy of an Esc can never pass for a new one. An unset or future time is taken as now.
    let now = at(0)
    let seconds = Double(now.nanoseconds) / 1e9
    #expect(HostTime(carbonEventTime: seconds - 0.005, now: now) == HostTime(nanoseconds: now.nanoseconds - 5_000_000))
    #expect(HostTime(carbonEventTime: seconds - 2, now: now) == HostTime(nanoseconds: now.nanoseconds - 2_000_000_000))
    #expect(HostTime(carbonEventTime: 0, now: now) == now)
    #expect(HostTime(carbonEventTime: seconds + 1, now: now) == now)
    #expect(HostTime(carbonEventTime: .infinity, now: now) == now)
    #expect(HostTime(carbonEventTime: .nan, now: now) == now)
}

@Test func theFnKeysOwnKeyDownIsNotAnotherKey() {
    // On a Mac with the Globe key, macOS can send a key-down for fn itself (keycode 63, or 179
    // for Globe) when a short tap is released. It is fn, not a chord: it must not end the tap.
    let fnKeyDown = keyEvent(63)
    fnKeyDown.type = .keyDown  // built for keycode 63, CGEvent makes a flag change
    #expect(KeyInput(fnKeyDown, secureInput: { false }, now: at(0)) == nil)
    #expect(KeyInput(keyEvent(179), secureInput: { false }, now: at(0)) == nil)
}

@Test func aRealDoubleTapWithTheGlobeKeyDownStartsHandsFree() throws {
    // A real tap as the Live checks sitting saw it: fn down, fn up, then fn's own key-down at the
    // release, then the second fn-down inside the window. It confirms hands-free, not a dropped tap.
    var gesture = FnGesture(KeyboardConfig())
    var commands = feed(flagsChanged(63, [.maskSecondaryFn]), at: at(0), into: &gesture)
    commands += feed(flagsChanged(63, []), at: at(100), into: &gesture)
    commands += feed(keyEvent(179), at: at(100), into: &gesture)
    commands += feed(flagsChanged(63, [.maskSecondaryFn]), at: at(200), into: &gesture)
    let id = try #require(beganID(commands))
    #expect(commands == [.dictationBegan(id, at: at(0)), .dictationConfirmed(id, .handsFree)])
}

@Test func theFnKeysOwnKeyDownIsNotTyping() {
    // fn's own key-down is fn, not Jake typing: it must not make a hands-free stop look like
    // he typed after it, which would hold the text for paste-last. A letter still counts.
    let input = InputClock()
    let (_, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = EventTapThread(gesture: FnGesture(KeyboardConfig()), input: input, continuation: continuation,
                             secureInput: { false })
    func fromKeyboard(_ event: CGEvent) -> CGEvent {
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }
    let mark = input.mark()
    _ = tap.handle(.keyDown, fromKeyboard(keyEvent(179)))
    #expect(!input.hasInput(since: mark))
    _ = tap.handle(.keyDown, fromKeyboard(keyEvent(0)))
    #expect(input.hasInput(since: mark))
}

/// As the keyboard sends it (pid 0): the tap drops events this process posted.
private func fromKeyboard(_ event: CGEvent) -> CGEvent {
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    return event
}

/// Whether `commands` stops the Dictation `id`: a stop, not a discard or a cancel.
private func stops(_ id: DictationID, in commands: [KeyCommand]) -> Bool {
    commands.contains { command in
        if case .dictationStopped(let stopped, _) = command { stopped == id } else { false }
    }
}

@Test func aTimeoutEndsAPressWhenFnIsNoLongerDown() async throws {
    // The tap was turned off with fn's release lost in the gap. The timeout is the only
    // fn-up this press will get, so it must end the press.
    let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = EventTapThread(gesture: FnGesture(KeyboardConfig(holdThreshold: .zero)), input: InputClock(),
                             continuation: continuation, secureInput: { false }, fnHeld: { false })
    _ = tap.handle(.flagsChanged, fromKeyboard(flagsChanged(63, [.maskSecondaryFn])))
    _ = tap.handle(.tapDisabledByTimeout, keyEvent(0))
    continuation.finish()
    var yielded: [KeyCommand] = []
    for await command in commands { yielded.append(command) }
    let id = try #require(beganID(yielded))
    #expect(stops(id, in: yielded))
}

@Test func aTimeoutLeavesAPressAloneWhileFnIsStillHeld() async throws {
    // fn is still down at the timeout, so the press goes on: the timeout must not stop a
    // Dictation Jake is still holding. The press itself is checked first, so the absence means something.
    let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = EventTapThread(gesture: FnGesture(KeyboardConfig(holdThreshold: .zero)), input: InputClock(),
                             continuation: continuation, secureInput: { false }, fnHeld: { true })
    _ = tap.handle(.flagsChanged, fromKeyboard(flagsChanged(63, [.maskSecondaryFn])))
    _ = tap.handle(.tapDisabledByTimeout, keyEvent(0))
    continuation.finish()
    var yielded: [KeyCommand] = []
    for await command in commands { yielded.append(command) }
    _ = try #require(beganID(yielded))
    #expect(!yielded.contains { if case .dictationStopped = $0 { true } else { false } })
}

@Test func aFnUpAfterATimeoutWhileFnWasHeldStillStopsTheDictation() async throws {
    // The press the timeout left alone ends on the real fn-up, as any hold does.
    let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = EventTapThread(gesture: FnGesture(KeyboardConfig(holdThreshold: .zero)), input: InputClock(),
                             continuation: continuation, secureInput: { false }, fnHeld: { true })
    _ = tap.handle(.flagsChanged, fromKeyboard(flagsChanged(63, [.maskSecondaryFn])))
    _ = tap.handle(.tapDisabledByTimeout, keyEvent(0))
    _ = tap.handle(.flagsChanged, fromKeyboard(flagsChanged(63, [])))
    continuation.finish()
    var yielded: [KeyCommand] = []
    for await command in commands { yielded.append(command) }
    let id = try #require(beganID(yielded))
    #expect(stops(id, in: yielded))
}

@Test func aTimeoutWithNoPressInProgressYieldsNothingAndDoesNotAskAboutFn() async {
    // Nothing to end: the tap is re-enabled, and the system's fn state is not even read.
    let asked = Mutex(0)
    let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = EventTapThread(gesture: FnGesture(KeyboardConfig(holdThreshold: .zero)), input: InputClock(),
                             continuation: continuation, secureInput: { false },
                             fnHeld: { asked.withLock { $0 += 1 }; return false })
    _ = tap.handle(.tapDisabledByTimeout, keyEvent(0))
    continuation.finish()
    var yielded: [KeyCommand] = []
    for await command in commands { yielded.append(command) }
    #expect(yielded.isEmpty)
    #expect(asked.withLock { $0 } == 0)
}

// When a deadline timer fires late, the tap thread was stalled, and keys queued behind the
// stall may still be unhandled. The deferral rule lets those keys go first, so the recognizer
// never judges a window or a hold on a late `now` before it has seen them. A timer up to one
// grace late feeds at once: each mark acts one grace after its own time, so its timer is already
// due one grace after the mark, and deferring it again would make the mark act two graces late.

@Test func deferralIsNilForATimerOnTime() {
    let due = at(300)
    #expect(EventTapThread.deferral(due: due, now: due) == nil)
}

@Test func aTimerUpToOneGraceLateFeedsAndOneJustPastDefers() {
    // One grace is how late a key may be handled and still count against a mark, so a timer that
    // fires that late feeds at once. Just past it, keys may be queued behind the stall: wait one grace.
    let due = at(300)
    #expect(EventTapThread.deferral(due: due, now: due.advanced(by: FnGesture.lateKeyGrace)) == nil)
    let now = due.advanced(by: FnGesture.lateKeyGrace + Duration.nanoseconds(1))
    #expect(EventTapThread.deferral(due: due, now: now) == now.advanced(by: FnGesture.lateKeyGrace))
}

@Test func aTimerPastOneGraceLateDefersToOneGraceFromNow() {
    // Past the grace, keys may still be queued behind the stall: wait one grace, so they are handled first.
    let due = at(300)
    let now = due.advanced(by: FnGesture.lateKeyGrace + Duration.milliseconds(1))
    #expect(EventTapThread.deferral(due: due, now: now) == now.advanced(by: FnGesture.lateKeyGrace))
}

@Test func aStalledTimerDefersToOneGraceFromNow() throws {
    // After a 2 s stall the timer waits one grace from now. Whether the re-armed timer defers again
    // is tested in aTimerStalledAgainDefersAgain.
    let due = at(300)
    let stalledNow = due.advanced(by: .seconds(2))
    let rearmed = try #require(EventTapThread.deferral(due: due, now: stalledNow))
    #expect(rearmed == stalledNow.advanced(by: FnGesture.lateKeyGrace))
}

// The timer's handler, run on a tap never started: `deadlineFired` is the body of the timer.

/// Ten seconds before the real clock, read once per test. `handle` takes a stamp past the real clock
/// as now, and `at` is about ten days of uptime, which a young Mac has not reached, so a test that
/// feeds events through `handle` stamps from here. One base per test keeps the gaps between stamps exact.
private func recentBase() -> HostTime {
    HostTime.now().advanced(by: .seconds(-10))
}

/// fn pressed or released, as the keyboard sends it, carrying its own event time.
private func fnEvent(down: Bool, stamped stamp: HostTime) -> CGEvent {
    let flags: CGEventFlags = down ? [.maskSecondaryFn] : []
    let event = flagsChanged(63, flags)
    event.timestamp = stamp.nanoseconds
    return fromKeyboard(event)
}

@Test func aLateHoldDeadlineLetsAQueuedShortTapGoFirst() async throws {
    // fn goes down at 0 and the 300 ms deadline fires 100 ms late, while fn-up (stamped 290 ms) still
    // waits in the queue behind the stall. Later than one grace, the deadline waits one grace, so fn-up
    // is judged first: the press was a tap, and a late timer must not confirm a hold. The re-armed
    // timer then fires on time.
    let base = recentBase()
    let deadline = base.advanced(by: .milliseconds(300))
    let firedAt = deadline.advanced(by: .milliseconds(100))
    let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = EventTapThread(gesture: FnGesture(KeyboardConfig()), input: InputClock(), continuation: continuation,
                             secureInput: { false }, fnHeld: { true })
    _ = tap.handle(.flagsChanged, fnEvent(down: true, stamped: base))
    tap.deadlineFired(due: deadline, now: firedAt)
    _ = tap.handle(.flagsChanged, fnEvent(down: false, stamped: base.advanced(by: .milliseconds(290))))
    let rearmed = firedAt.advanced(by: FnGesture.lateKeyGrace)
    tap.deadlineFired(due: rearmed, now: rearmed)
    continuation.finish()
    var yielded: [KeyCommand] = []
    for await command in commands { yielded.append(command) }
    let id = try #require(beganID(yielded))
    #expect(!yielded.contains(.dictationConfirmed(id, .hold)))
    #expect(!yielded.contains { if case .dictationStopped = $0 { true } else { false } })
}

@Test func aTimerStalledAgainDefersAgain() throws {
    // A timer re-armed by a deferral is judged like any other: if the stall is still going when it
    // fires, it waits one grace again. Only a re-armed timer that fires on time feeds.
    let due = at(300)
    let rearmed = try #require(EventTapThread.deferral(due: due, now: due.advanced(by: .milliseconds(100))))
    let stalledAgain = rearmed.advanced(by: .milliseconds(100))
    #expect(EventTapThread.deferral(due: rearmed, now: stalledAgain) == stalledAgain.advanced(by: FnGesture.lateKeyGrace))
    #expect(EventTapThread.deferral(due: rearmed, now: rearmed) == nil)
}

@Test func aTimerOnTimeFeedsAtOnce() async throws {
    // A deadline that fires on time feeds the recognizer, which confirms the hold there. Deferred,
    // nothing would confirm it: no later deadline is delivered in this test.
    let base = recentBase()
    let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = EventTapThread(gesture: FnGesture(KeyboardConfig()), input: InputClock(), continuation: continuation,
                             secureInput: { false }, fnHeld: { true })
    _ = tap.handle(.flagsChanged, fnEvent(down: true, stamped: base))
    let due = base.advanced(by: .milliseconds(300))
    tap.deadlineFired(due: due, now: due)
    continuation.finish()
    var yielded: [KeyCommand] = []
    for await command in commands { yielded.append(command) }
    let id = try #require(beganID(yielded))
    #expect(yielded.contains(.dictationConfirmed(id, .hold)))
}

@Test func aMarkTimerTwentyMillisecondsLateActsAtOnce() async throws {
    // The double-tap window closes at fn-up plus the window, and its drop is due one grace after that.
    // A timer 20 ms late is within one grace, so it drops the lone tap at once. Deferring it again
    // would drop it 100 ms after the mark, against DECISIONS.md item 79's 50 ms.
    let base = recentBase()
    let config = KeyboardConfig()
    let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
    let tap = EventTapThread(gesture: FnGesture(config), input: InputClock(), continuation: continuation,
                             secureInput: { false }, fnHeld: { false })
    _ = tap.handle(.flagsChanged, fnEvent(down: true, stamped: base))
    let fnUp = base.advanced(by: .milliseconds(100))
    _ = tap.handle(.flagsChanged, fnEvent(down: false, stamped: fnUp))
    let drop = fnUp.advanced(by: config.doubleTapWindow + FnGesture.lateKeyGrace)
    tap.deadlineFired(due: drop, now: drop.advanced(by: .milliseconds(20)))
    continuation.finish()
    var yielded: [KeyCommand] = []
    for await command in commands { yielded.append(command) }
    let id = try #require(beganID(yielded))
    #expect(yielded.contains(.dictationDiscarded(id)))
}

@Test func aDoubleTapWhoseSecondFnDownWasQueuedBehindAStallBecomesHandsFree() throws {
    // The second fn-down is stamped 250 ms but read after a stall, when the window's deadline has
    // come late. Handled before that deadline, the press is still inside the window: hands-free,
    // not a lone tap discarded.
    var gesture = FnGesture(KeyboardConfig())
    var commands = feed(flagsChanged(63, [.maskSecondaryFn]), at: at(0), into: &gesture)
    commands += feed(flagsChanged(63, []), at: at(100), into: &gesture)
    let queuedDown = flagsChanged(63, [.maskSecondaryFn])
    queuedDown.timestamp = at(250).nanoseconds
    commands += feed(queuedDown, at: at(2000), into: &gesture)
    commands += gesture.handle(.deadline(at(2000))).commands
    let id = try #require(beganID(commands))
    #expect(commands.contains(.dictationConfirmed(id, .handsFree)))
    #expect(!commands.contains(.dictationDiscarded(id)))
}
