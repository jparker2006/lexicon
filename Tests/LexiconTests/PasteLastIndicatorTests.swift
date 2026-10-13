import Testing
import LexiconDomain
import LexiconCore
import LexiconUI

// Paste-last (#62) tells the pill when the text was typed. The pill's rules are
// pure, so they are checked without a window (drawing is in the live app).

private let live = DictationID(), other = DictationID()

/// Feeds the events in order; returns the state after the last one and the sound the last one called for.
private func run(_ events: [ConductorEvent]) -> (state: IndicatorState, sound: SoundCue?) {
    var follower = IndicatorFollower()
    var sound: SoundCue?
    for event in events { sound = follower.apply(event) }
    return (follower.state, sound)
}

@Test func aPasteLastThatTypesClearsTheNotTypedPillAtOnce() {
    // A live Dictation that was not typed shows "Not typed" (paste-last) first.
    let shown = run([.confirmed(live, .hold), .stopped(live), .notice(.readyToPaste(live)),
                     .finished(live, .notInserted)])
    #expect(shown.state == .pasteLast)

    // The paste lands: the pill stops saying "Not typed" at once, with no sound.
    let typed = run([.confirmed(live, .hold), .stopped(live), .notice(.readyToPaste(live)),
                     .finished(live, .notInserted), .pasted(live, newerOnItsWay: false)])
    #expect(typed.state == .landed)
    #expect(typed.sound == nil)
}

@Test func aPasteLastOfTheOneBeforeSaysTheNewestIsOnItsWay() {
    // The one before the newest was pasted while the newest is still being made.
    let step = run([.pasted(live, newerOnItsWay: true)])
    #expect(step.state == .error("Pasted the one before. The newest is on its way"))
    #expect(step.sound == nil)
}

@Test func aPasteLastWhileRecordingLeavesTheRecordingShowing() {
    // Guard: passes at this head because the stub ignores `.pasted`. It keeps the rule from
    // regressing when `.pasted` is filled in: a paste never covers the recording Jake is making.
    let step = run([.confirmed(live, .hold), .pasted(other, newerOnItsWay: false)])
    #expect(step.state == .recording(.hold, minuteLeft: false))
    #expect(step.sound == nil)
}

@Test func aPasteLastFromHiddenShowsTheCheck() {
    // Nothing was showing (the pill was hidden), and the paste still shows the check.
    let step = run([.pasted(live, newerOnItsWay: false)])
    #expect(step.state == .landed)
}
