import Testing
import AppText
import LexiconDomain

// The late-text rule (#60) as pure values: the focus at fn-up, the focus right
// before the paste, whether Jake typed since the mark, and how long after fn-up
// the paste comes. No clock and no Accessibility. The 5 s limit applies only where
// an app exposes no focused field; a detected field has no time limit.

/// The field Jake was in at fn-up.
private let field = FocusSnapshot(pid: 42, fieldFingerprint: "field")
/// The same app at fn-up, when it exposes no focused field.
private let fieldless = FocusSnapshot(pid: 42, fieldFingerprint: nil)

@Test func aDetectedFieldInTheSameAppInsertsLongAfterFnUp() {
    #expect(InsertGuard.decide(target: field, focusNow: field, inputSinceMark: false,
                               sinceCapture: .seconds(60)) == .insert)
}

@Test(arguments: [
    // Another field in the same app.
    FocusSnapshot(pid: 42, fieldFingerprint: "other"),
    // The same field string, but another app.
    FocusSnapshot(pid: 43, fieldFingerprint: "field"),
])
func aSwitchedFieldOrAppHoldsTheTextAsFocusMoved(_ focusNow: FocusSnapshot) {
    #expect(InsertGuard.decide(target: field, focusNow: focusNow, inputSinceMark: false,
                               sinceCapture: .seconds(1)) == .hold(.focusMoved))
}

@Test func typingSinceFnUpHoldsTheTextAsTypedSince() {
    #expect(InsertGuard.decide(target: field, focusNow: field, inputSinceMark: true,
                               sinceCapture: .seconds(1)) == .hold(.typedSince))
}

@Test(arguments: [field, fieldless])
func nothingFocusedNowHoldsTheTextAsNoField(_ target: FocusSnapshot) {
    // nil is "nothing can take text", which is not the same as a snapshot with no field.
    #expect(InsertGuard.decide(target: target, focusNow: nil, inputSinceMark: false,
                               sinceCapture: .seconds(1)) == .hold(.noField))
}

@Test func aFieldlessAppInsertsUntilFiveSecondsAfterFnUpThenHoldsAsTooLate() {
    #expect(InsertGuard.decide(target: fieldless, focusNow: fieldless, inputSinceMark: false,
                               sinceCapture: .milliseconds(4_999)) == .insert)
    #expect(InsertGuard.decide(target: fieldless, focusNow: fieldless, inputSinceMark: false,
                               sinceCapture: .seconds(5)) == .hold(.tooLate))
    #expect(InsertGuard.decide(target: fieldless, focusNow: fieldless, inputSinceMark: false,
                               sinceCapture: .seconds(30)) == .hold(.tooLate))
}

@Test func aFieldAppearingInTheSameAppAfterFnUpHoldsAsFocusMoved() {
    #expect(InsertGuard.decide(target: fieldless, focusNow: field, inputSinceMark: false,
                               sinceCapture: .milliseconds(4_999)) == .hold(.focusMoved))
}

@Test func aFieldLostInTheSameAppAfterFnUpHoldsAsFocusMoved() {
    // The app now exposes no focused field: a changed snapshot, not nothing to type into.
    #expect(InsertGuard.decide(target: field, focusNow: fieldless, inputSinceMark: false,
                               sinceCapture: .seconds(1)) == .hold(.focusMoved))
}

@Test func typingSinceFnUpHoldsFieldlessTextAsTypedSinceUnderFiveSeconds() {
    #expect(InsertGuard.decide(target: fieldless, focusNow: fieldless, inputSinceMark: true,
                               sinceCapture: .milliseconds(4_999)) == .hold(.typedSince))
}

@Test(arguments: [
    // Another app with no field, and another app with a field.
    FocusSnapshot(pid: 43, fieldFingerprint: nil),
    FocusSnapshot(pid: 43, fieldFingerprint: "field"),
])
func aSwitchedAppHoldsFieldlessTextAsFocusMovedEvenUnderFiveSeconds(_ focusNow: FocusSnapshot) {
    #expect(InsertGuard.decide(target: fieldless, focusNow: focusNow, inputSinceMark: false,
                               sinceCapture: .milliseconds(4_999)) == .hold(.focusMoved))
}
