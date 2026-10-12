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
// read, so the text is held. A slow answer can only ever hold text, never paste it.
// AXError raw values: success 0, noValue -25212, attributeUnsupported -25205,
// notImplemented -25208, cannotComplete -25204 (a timeout), failure -25200,
// apiDisabled -25211, invalidUIElement -25202.
@Test(arguments: [(Int32(0), Focus.Answer.element), (-25212, .none), (-25205, .none), (-25208, .none),
                  (-25204, .unreadable), (-25200, .unreadable), (-25211, .unreadable), (-25202, .unreadable)])
func anAppsFocusedElementAnswerIsAFieldNoFieldOrUnreadable(_ code: Int32, _ expected: Focus.Answer) {
    #expect(Focus.Answer(code) == expected)
}
