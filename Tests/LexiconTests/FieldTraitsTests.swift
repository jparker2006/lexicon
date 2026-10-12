import Testing
@testable import AppText

private func traits(_ role: String?, subrole: String? = nil, settable: Bool = false,
                    editable: Bool = false) -> FieldTraits {
    FieldTraits(role: role, subrole: subrole, valueSettable: settable, editableAncestor: editable)
}

@Test(arguments: [
    (traits("AXTextField"), FieldTraits.Accepts.text),
    (traits("AXTextArea"), .text),  // Terminal, NSTextView
    (traits("AXComboBox"), .text),
    (traits("AXGroup", editable: true), .text),  // a Chromium or Electron contenteditable
    (traits("AXGroup", settable: true), .text),
    (traits("AXTextField", subrole: "AXSecureTextField"), .secure),
    (traits("AXSecureTextField"), .secure),
    // Chrome reads the pasteboard on Cmd-V with a link focused, and nothing lands.
    (traits("AXLink"), .nothing),
    (traits("AXButton"), .nothing),
    (traits("AXWebArea"), .nothing),
    (traits(nil), .nothing),
])
func aPasteGoesOnlyWhereTheFocusedElementTakesText(traits: FieldTraits, expected: FieldTraits.Accepts) {
    #expect(FieldTraits.accepts(traits) == expected)
}

// What an app's focused-element answer means for the late-text rule, on every
// path to the focus (#60): an element is a field, a definite "none" is an app
// with no field (the 5 s rule), and anything else, a timeout included, can't be
// read. An app that never answers only ever holds text.
// AXError raw values: success 0, noValue -25212, attributeUnsupported -25205,
// notImplemented -25208, cannotComplete -25204 (a timeout), failure -25200,
// apiDisabled -25211, invalidUIElement -25202.
@Test(arguments: [(Int32(0), Focus.Answer.element), (-25212, .none), (-25205, .none), (-25208, .none),
                  (-25204, .unreadable), (-25200, .unreadable), (-25211, .unreadable), (-25202, .unreadable)])
func anAppsFocusedElementAnswerIsAFieldNoFieldOrUnreadable(_ code: Int32, _ expected: Focus.Answer) {
    #expect(Focus.Answer(code) == expected)
}

// One slow or failed read is not the app's answer: the focus is read once more
// before it is called unreadable, but the retry counts only if it names the same
// app. Focus that moved meanwhile, with no key or click from Jake (an app that
// activates itself, a panel that takes keys), never becomes the target.
@Test func aFocusRetryOfTheSameAppIsUsed() {
    var answers: [Focus.Answer] = [.unreadable, .element]
    var named = 0
    let field = Focus.readTwice(naming: { () -> String? in named += 1; return "Notes" },
                                answering: { app in (answers.removeFirst(), "\(app) field") })
    #expect(field == "Notes field")
    #expect(named == 2)
}

@Test func aFocusRetryNeverTakesTheAppFocusMovedTo() {
    var focused = ["Notes", "Finder"]
    let target = Focus.readTwice(
        naming: { () -> String? in focused.isEmpty ? nil : focused.removeFirst() },
        answering: { (app: String) -> (Focus.Answer, String?) in
            if app == "Notes" { return (.unreadable, nil) }
            return (.element, "\(app) field")
        })
    #expect(target == nil)
}

@Test func aDefiniteAnswerIsReadOnce() {
    var reads = 0
    #expect(Focus.readTwice(naming: { "Finder" }, answering: { app in reads += 1; return (.none, app) }) == "Finder")
    #expect(reads == 1)
}

@Test func aFocusReadThatFailsTwiceIsUnreadable() {
    var reads = 0
    #expect(Focus.readTwice(naming: { "Finder" }, answering: { (_: String) -> (Focus.Answer, String?) in
        reads += 1
        return (.unreadable, nil)
    }) == nil)
    #expect(reads == 2)
}

@Test func withNoAppNamedThereIsNothingToRetry() {
    var asks = 0
    #expect(Focus.readTwice(naming: { () -> String? in asks += 1; return nil }, answering: { app in (.none, app) }) == nil)
    #expect(asks == 1)
}
