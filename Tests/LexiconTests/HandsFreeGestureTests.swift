import Testing
@testable import KeyInput
import LexiconDomain

// The hands-free, Esc and cap rules of the fn recognizer (#58). Pure: scripted
// inputs on a fake clock, where every time is milliseconds after an arbitrary
// fn-down at t0. The rules are read off the commands, the wake-up mark,
// `isRecording` and `takesEscape`, never off the phase.

private let t0: UInt64 = 5_000_000_000

/// Hold 0.30 s, double tap 0.25 s, and a 10 s cap with the warning 2 s before it:
/// counted from the first fn-down, the warning is due at 8 s and the stop at 10 s.
private let shortCap = KeyboardConfig(holdThreshold: .milliseconds(300), doubleTapWindow: .milliseconds(250),
                                      cap: .seconds(10), capWarning: .seconds(2))

/// The Dictations the presses below start, in order.
private let a = DictationID(), b = DictationID(), c = DictationID(), d = DictationID()

/// Milliseconds after t0.
private func at(_ milliseconds: Int) -> HostTime {
    HostTime(nanoseconds: t0 + UInt64(milliseconds) * 1_000_000)
}

/// Feeds `inputs` in order and returns every command, in order.
private func run(_ inputs: [KeyInput], gesture: inout FnGesture) -> [KeyCommand] {
    inputs.flatMap { gesture.handle($0).commands }
}

@Test func aLoneReleaseWaitsForASecondTapInsteadOfDiscarding() {
    // The first half of a double tap: the release emits nothing, and the recognizer
    // asks to be woken one window (0.25 s) and the late-key grace (50 ms) after the release.
    var gesture = FnGesture(shortCap)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    let release = gesture.handle(.fnUp(at(90)))
    #expect(release.commands.isEmpty)
    #expect(release.wakeAt == at(390))
    #expect(gesture.isRecording)
}

@Test(arguments: [(240, true), (250, true), (260, false)])
func aSecondPressInsideTheWindowMakesItHandsFree(gap: Int, isDoubleTap: Bool) {
    // The window is 0.25 s after the release, inclusive. Inside it, the second press
    // confirms hands-free for the first Dictation and starts none of its own. After it,
    // the first tap is discarded and the second press begins a new Dictation.
    var gesture = FnGesture(shortCap)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    #expect(gesture.handle(.fnUp(at(90))).commands.isEmpty)
    let second = gesture.handle(.fnDown(at(90 + gap), secureInput: false, id: b))
    #expect(second.commands == (isDoubleTap
        ? [.dictationConfirmed(a, .handsFree)]
        : [.dictationDiscarded(a), .dictationBegan(b, at: at(90 + gap))]))
}

@Test func aLoneTapIsDiscardedWhenTheWindowCloses() {
    // With no second press by the wake-up mark (0.39 s), the tap is discarded.
    var gesture = FnGesture(shortCap)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    _ = gesture.handle(.fnUp(at(90)))
    #expect(gesture.handle(.deadline(at(390))).commands == [.dictationDiscarded(a)])
    #expect(!gesture.isRecording)
}

@Test func thePressThatStopsHandsFreeStartsNoDoubleTap() {
    // The stop press's fn-up lands in idle, so a press 120 ms after it begins a new
    // Dictation. It is never read as the second tap of a double tap.
    var gesture = FnGesture(shortCap)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    _ = gesture.handle(.fnUp(at(90)))
    #expect(gesture.handle(.fnDown(at(200), secureInput: false, id: b)).commands == [.dictationConfirmed(a, .handsFree)])
    #expect(gesture.handle(.fnUp(at(230))).commands.isEmpty)
    // The stop: a fn-down while hands-free is recording ends it at that time.
    #expect(gesture.handle(.fnDown(at(1_000), secureInput: false, id: c)).commands == [.dictationStopped(a, at: at(1_000))])
    #expect(!gesture.isRecording)
    #expect(gesture.handle(.fnUp(at(1_080))).commands.isEmpty)
    #expect(gesture.handle(.fnDown(at(1_200), secureInput: false, id: d)).commands == [.dictationBegan(d, at: at(1_200))])
    #expect(gesture.isRecording)
}

@Test func handsFreeKeepsRecordingThroughReleasesAndKeys() {
    // Hands-free: a release does nothing, and a key passes through without ending it.
    var gesture = FnGesture(shortCap)
    #expect(run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90)), .fnDown(at(200), secureInput: false, id: b)],
                gesture: &gesture)
        == [.dictationBegan(a, at: at(0)), .dictationConfirmed(a, .handsFree)])
    #expect(gesture.handle(.fnUp(at(230))).commands.isEmpty)
    #expect(gesture.handle(.otherKey(at(500))).commands.isEmpty)
    #expect(gesture.handle(.fnUp(at(900))).commands.isEmpty)
    #expect(gesture.isRecording)
}

@Test func escInAConfirmedHoldCancelsTheDictationOnce() {
    // Esc cancels: the Dictation is still transcribed and saved, but nothing is typed.
    // A second Esc finds nothing to end, and the release that follows does nothing.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300))], gesture: &gesture)
    #expect(gesture.handle(.escape(at(500))).commands == [.dictationCancelled(a)])
    #expect(!gesture.isRecording)
    #expect(gesture.handle(.escape(at(510))).commands.isEmpty)
    #expect(gesture.handle(.fnUp(at(600))).commands.isEmpty)
}

@Test func escInHandsFreeCancelsTheDictation() {
    // Hands-free is a confirmed recording too: Esc cancels it the same way.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90)), .fnDown(at(200), secureInput: false, id: b)],
            gesture: &gesture)
    #expect(gesture.handle(.escape(at(500))).commands == [.dictationCancelled(a)])
    #expect(!gesture.isRecording)
}

@Test(arguments: [(290, false), (299, false), (300, true), (310, true)])
func escBeforeTheHoldThresholdDiscardsAndAtOrAfterItConfirmsThenCancels(milliseconds: Int, isHold: Bool) {
    // No deadline delivered yet, so Esc's own time decides, as a key's does. Under the
    // threshold the press is a lone tap and is discarded. At or past it, the press is a
    // hold: confirmed, then cancelled.
    var gesture = FnGesture(shortCap)
    let commands = run([.fnDown(at(0), secureInput: false, id: a), .escape(at(milliseconds))], gesture: &gesture)
    #expect(commands == (isHold
        ? [.dictationBegan(a, at: at(0)), .dictationConfirmed(a, .hold), .dictationCancelled(a)]
        : [.dictationBegan(a, at: at(0)), .dictationDiscarded(a)]))
    #expect(!gesture.isRecording)
}

@Test func escInTheTapGapDiscardsTheTap() {
    // A tap that has not become a Dictation yet: Esc discards it, and nothing is kept.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90))], gesture: &gesture)
    #expect(gesture.handle(.escape(at(150))).commands == [.dictationDiscarded(a)])
    #expect(!gesture.isRecording)
    // The wake-up mark the release asked for is stale now.
    #expect(gesture.handle(.deadline(at(340))).commands.isEmpty)
}

@Test func aHoldAsksForTheWarningAtTheCapCountedFromTheFirstFnDown() {
    // Confirmed at 0.3 s, the hold asks for the warning at 8 s: the cap's 10 s is counted
    // from the first fn-down at 0 s, less the 2 s warning.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a)], gesture: &gesture)
    let confirm = gesture.handle(.deadline(at(300)))
    #expect(confirm.commands == [.dictationConfirmed(a, .hold)])
    #expect(confirm.wakeAt == at(8_050))
}

@Test func aHandsFreeAsksForTheWarningCountedFromTheFirstFnDownNotTheSecondTap() {
    // The second tap at 0.2 s confirms hands-free, and the mark is still 8 s after the
    // first fn-down, not 8 s after the second press.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90))], gesture: &gesture)
    let confirm = gesture.handle(.fnDown(at(200), secureInput: false, id: b))
    #expect(confirm.commands == [.dictationConfirmed(a, .handsFree)])
    #expect(confirm.wakeAt == at(8_050))
}

@Test(arguments: [false, true])
func theWarningSoundsOnceAndTheCapStopsTheDictationInBothModes(handsFree: Bool) {
    // Warned at 8 s and stopped at 10 s, both counted from the first fn-down.
    var gesture = FnGesture(shortCap)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    if handsFree {
        _ = gesture.handle(.fnUp(at(90)))
        _ = gesture.handle(.fnDown(at(200), secureInput: false, id: b))
    } else {
        _ = gesture.handle(.deadline(at(300)))
    }
    let warning = gesture.handle(.deadline(at(8_050)))
    #expect(warning.commands == [.oneMinuteLeft(a)])
    #expect(warning.wakeAt == at(10_050))
    // Once only: the same mark again sends nothing, and the stop is still due at 10 s.
    #expect(gesture.handle(.deadline(at(8_050))).commands.isEmpty)
    #expect(gesture.handle(.deadline(at(10_050))).commands == [.dictationStopped(a, at: at(10_000))])
    #expect(!gesture.isRecording)
}

@Test func anEarlyWarningDeadlineAsksAgainForTheSameMark() {
    // A timer that fires at 7.99 s confirms nothing: the mark stays at 8 s, and the
    // warning sounds when the mark is delivered.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300))], gesture: &gesture)
    let early = gesture.handle(.deadline(at(7_990)))
    #expect(early.commands.isEmpty)
    #expect(early.wakeAt == at(8_050))
    #expect(gesture.handle(.deadline(at(8_050))).commands == [.oneMinuteLeft(a)])
}

@Test func aCapDeadlineDeliveredLateStopsAtTheCapMark() {
    // Delivered at 10.4 s, the stop is still stamped at the cap: 10 s after the first fn-down.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300)), .deadline(at(8_050))], gesture: &gesture)
    #expect(gesture.handle(.deadline(at(10_400))).commands == [.dictationStopped(a, at: at(10_000))])
    #expect(!gesture.isRecording)
}

@Test func aLostFnUpInAHoldEndsAtTheCap() {
    // No release ever arrives: the warning and then the cap end the Dictation, and a
    // release after that does nothing.
    var gesture = FnGesture(shortCap)
    #expect(run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300)), .deadline(at(8_050)), .deadline(at(10_050))],
                gesture: &gesture)
        == [.dictationBegan(a, at: at(0)), .dictationConfirmed(a, .hold), .oneMinuteLeft(a), .dictationStopped(a, at: at(10_000))])
    #expect(!gesture.isRecording)
    #expect(gesture.handle(.fnUp(at(10_500))).commands.isEmpty)
}

@Test func sleepInAHoldStopsItAndTheCapMarkDoesNothingAfter() {
    // A hold confirmed at 0.3 s asks for the warning at 8 s. Lid close stops the hold at
    // 0.8 s, and the mark it had asked for then does nothing.
    var gesture = FnGesture(shortCap)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    #expect(gesture.handle(.deadline(at(300))).wakeAt == at(8_050))
    #expect(gesture.handle(.sleep(at(800))).commands == [.dictationStopped(a, at: at(800))])
    #expect(!gesture.isRecording)
    #expect(gesture.handle(.deadline(at(8_050))).commands.isEmpty)
}

@Test func sleepInHandsFreeStopsIt() {
    // Lid close ends a hands-free Dictation the way a release would.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90)), .fnDown(at(200), secureInput: false, id: b)],
            gesture: &gesture)
    #expect(gesture.handle(.sleep(at(800))).commands == [.dictationStopped(a, at: at(800))])
    #expect(!gesture.isRecording)
    #expect(gesture.handle(.fnUp(at(900))).commands.isEmpty)
}

@Test func sleepInTheTapGapDiscardsTheTap() {
    // A tap that has not become a Dictation yet: sleep discards it.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90))], gesture: &gesture)
    #expect(gesture.handle(.sleep(at(150))).commands == [.dictationDiscarded(a)])
    #expect(!gesture.isRecording)
}

@Test func takesEscapeOnlyOnceAHoldIsConfirmed() {
    // Esc is taken from the app from the confirmed hold, never from the raw fn-down,
    // so a stray tap never eats Esc.
    var gesture = FnGesture(shortCap)
    #expect(!gesture.takesEscape)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    #expect(!gesture.takesEscape)
    _ = gesture.handle(.deadline(at(300)))
    #expect(gesture.takesEscape)
    _ = gesture.handle(.fnUp(at(900)))
    #expect(!gesture.takesEscape)
}

@Test func takesEscapeInHandsFreeAndNotInTheGapOrAfterTheStop() {
    // Hands-free takes Esc. The tap gap does not, and the stop press that ends
    // hands-free gives it back.
    var gesture = FnGesture(shortCap)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    _ = gesture.handle(.fnUp(at(90)))
    #expect(!gesture.takesEscape)
    _ = gesture.handle(.fnDown(at(200), secureInput: false, id: b))
    #expect(gesture.takesEscape)
    _ = gesture.handle(.fnDown(at(1_000), secureInput: false, id: c))
    #expect(!gesture.takesEscape)
}

@Test func aSecondTapStampedInsideTheWindowCountsWhenTheWindowsMarkIsHandledFirst() {
    // The press and the window's timer share the tap thread's run loop, so a press stamped
    // inside the window can be handled just after a timer at the window's end. The press's
    // own time decides: the window's mark waits a little before it drops the tap.
    var gesture = FnGesture(shortCap)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    _ = gesture.handle(.fnUp(at(90)))
    #expect(gesture.handle(.deadline(at(340))).commands.isEmpty)
    #expect(gesture.handle(.fnDown(at(335), secureInput: false, id: b)).commands == [.dictationConfirmed(a, .handsFree)])
}

@Test func aStopPressStampedBeforeTheCapStopsAtItsOwnTimeWhenTheCapsTimerComesFirst() {
    // The cap's mark acts 50 ms after the cap: a stop press stamped at 9.99 s and handled within
    // that stops the Dictation at its own time.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90)), .fnDown(at(200), secureInput: false, id: b),
             .deadline(at(8_050))], gesture: &gesture)
    #expect(gesture.handle(.deadline(at(10_000))).commands.isEmpty)
    #expect(gesture.handle(.fnDown(at(9_990), secureInput: false, id: b)).commands == [.dictationStopped(a, at: at(9_990))])
}

@Test func aStopPressHandledPastTheGraceIsNotANewPress() {
    // Past the bound (handled more than 50 ms after the cap): the cap has stopped the Dictation at
    // 10 s, and the press stamped before it is ignored by its own time, never a new press.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90)), .fnDown(at(200), secureInput: false, id: b),
             .deadline(at(8_050))], gesture: &gesture)
    #expect(gesture.handle(.deadline(at(10_050))).commands == [.dictationStopped(a, at: at(10_000))])
    #expect(gesture.handle(.fnDown(at(9_990), secureInput: false, id: b)) == FnGesture.Output())
    #expect(gesture.handle(.fnUp(at(10_040))) == FnGesture.Output())
    #expect(gesture.handle(.fnDown(at(10_100), secureInput: false, id: b)).commands == [.dictationBegan(b, at: at(10_100))])
}

@Test func aSecondTapWithSecureInputOnDropsTheTap() {
    // A password field took focus between the taps: never dictate into it.
    var gesture = FnGesture(shortCap)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    _ = gesture.handle(.fnUp(at(90)))
    #expect(gesture.handle(.fnDown(at(200), secureInput: true, id: b)).commands == [.dictationDiscarded(a)])
    #expect(!gesture.isRecording)
}

@Test func aSecondFnDownDuringAPressIsIgnored() {
    // Its fn-up was lost (the tap was briefly off): the press goes on, and its release judges it.
    var gesture = FnGesture(shortCap)
    _ = gesture.handle(.fnDown(at(0), secureInput: false, id: a))
    #expect(gesture.handle(.fnDown(at(100), secureInput: false, id: b)) == FnGesture.Output())
    #expect(gesture.phase == .pressed(a, since: at(0)))
}

@Test func theConductorEndingADictationGivesEscBack() {
    // The Conductor ended this Dictation itself (its mic never started): the recognizer forgets
    // it, so Esc reaches the apps again and the next fn-down begins a new press. An end for
    // any other Dictation changes nothing.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90)), .fnDown(at(200), secureInput: false, id: b)],
            gesture: &gesture)
    #expect(gesture.handle(.ended(b)) == FnGesture.Output())
    #expect(gesture.takesEscape)
    #expect(gesture.handle(.ended(a)) == FnGesture.Output())
    #expect(!gesture.takesEscape)
    #expect(gesture.handle(.fnDown(at(1_000), secureInput: false, id: b)).commands == [.dictationBegan(b, at: at(1_000))])
}

@Test func aPressStampedAfterTheCapGetsOneOutcomeWhicheverIsHandledFirst() {
    // The cap at 10 s and a press stamped at 10.01 s share the tap thread. Handled before the
    // cap's timer or after it, the cap stops the Dictation at 10 s and the press begins a new one.
    let capped: [KeyCommand] = [.dictationStopped(a, at: at(10_000)), .dictationBegan(b, at: at(10_010))]
    for keyFirst in [true, false] {
        var gesture = FnGesture(shortCap)
        _ = run([.fnDown(at(0), secureInput: false, id: a), .fnUp(at(90)), .fnDown(at(200), secureInput: false, id: b),
                 .deadline(at(8_050))], gesture: &gesture)
        let inputs: [KeyInput] = keyFirst
            ? [.fnDown(at(10_010), secureInput: false, id: b), .deadline(at(10_000))]
            : [.deadline(at(10_050)), .fnDown(at(10_010), secureInput: false, id: b)]
        #expect(run(inputs, gesture: &gesture) == capped)
    }
}

@Test func anEscStampedAfterTheCapDoesNotCancelTheCappedDictation() {
    // The cap stopped the Dictation at 10 s, to be typed; an Esc at 10.01 s handled before the
    // cap's timer comes after it all the same.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300)), .deadline(at(8_050))], gesture: &gesture)
    #expect(gesture.handle(.escape(at(10_010))).commands == [.dictationStopped(a, at: at(10_000))])
    #expect(gesture.handle(.deadline(at(10_000))).commands.isEmpty)
}

@Test(arguments: [true, false])
func anEscStampedJustBeforeTheCapCancelsWhicheverIsHandledFirst(escFirst: Bool) {
    // An Esc at 9.995 s cancels the Dictation, whether the tap handles it before or after the
    // cap's timer, within the 50 ms the cap's mark waits.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300)), .deadline(at(8_050))], gesture: &gesture)
    let inputs: [KeyInput] = escFirst ? [.escape(at(9_995)), .deadline(at(10_000))] : [.deadline(at(10_000)), .escape(at(9_995))]
    #expect(run(inputs, gesture: &gesture) == [.dictationCancelled(a)])
}

@Test(arguments: [true, false])
func aCappedDictationIsAlwaysWarnedFirst(keyFirst: Bool) {
    // The warning's mark was never handled (the tap thread was stalled): the cap still sends the
    // warning before its stop, whichever of the cap's timer and a later key comes first.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300))], gesture: &gesture)
    let inputs: [KeyInput] = keyFirst
        ? [.otherKey(at(10_010)), .deadline(at(10_050))]
        : [.deadline(at(10_050)), .otherKey(at(10_010))]
    #expect(run(inputs, gesture: &gesture) == [.oneMinuteLeft(a), .dictationStopped(a, at: at(10_000))])
}

@Test(arguments: [true, false])
func aKeyStampedAfterTheWarningMarkGetsTheWarningFirstWhicheverIsHandledFirst(keyFirst: Bool) {
    // Still recording at the warning's mark by its own time: the warning goes out once, before
    // whatever the key does, whether the tap handles the key or the mark's timer first.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300))], gesture: &gesture)
    let inputs: [KeyInput] = keyFirst ? [.escape(at(8_010)), .deadline(at(8_050))] : [.deadline(at(8_050)), .escape(at(8_010))]
    #expect(run(inputs, gesture: &gesture) == [.oneMinuteLeft(a), .dictationCancelled(a)])
}

@Test(arguments: [true, false])
func anEscStampedJustBeforeTheWarningMarkGetsNoWarningWhicheverIsHandledFirst(escFirst: Bool) {
    // An Esc at 7.99 s ends the Dictation before its warning, whether the tap handles it before
    // or after the warning's timer, within the 50 ms the warning's mark waits.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300))], gesture: &gesture)
    let inputs: [KeyInput] = escFirst ? [.escape(at(7_990)), .deadline(at(8_000))] : [.deadline(at(8_000)), .escape(at(7_990))]
    #expect(run(inputs, gesture: &gesture) == [.dictationCancelled(a)])
}

@Test func aLateCopyOfAnEscLeavesTheNextPressAlone() {
    // Esc at 1.0 s cancels a hold through one report; the other report of that same Esc (tap or
    // hotkey), stamped 1.0 s, is handled only after a new press began. It belongs to the press it
    // already ended, so it changes nothing, whatever phase the new press is in.
    var gesture = FnGesture(shortCap)
    _ = run([.fnDown(at(0), secureInput: false, id: a), .deadline(at(300))], gesture: &gesture)
    #expect(gesture.handle(.escape(at(1_000))).commands == [.dictationCancelled(a)])
    #expect(gesture.handle(.fnDown(at(1_100), secureInput: false, id: b)).commands == [.dictationBegan(b, at: at(1_100))])
    #expect(gesture.handle(.escape(at(1_000))).commands.isEmpty)  // pressed
    #expect(gesture.handle(.fnUp(at(1_150))).commands.isEmpty)
    #expect(gesture.handle(.escape(at(1_000))).commands.isEmpty)  // the double-tap gap
    #expect(gesture.handle(.fnDown(at(1_250), secureInput: false, id: DictationID())).commands
        == [.dictationConfirmed(b, .handsFree)])
    #expect(gesture.handle(.escape(at(1_000))).commands.isEmpty)  // hands-free
    #expect(gesture.takesEscape)
}
