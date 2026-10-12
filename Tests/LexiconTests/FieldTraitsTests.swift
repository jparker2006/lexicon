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

// An app in front whose focus the system-wide query can't name still gets
// Cmd-V, so it is a target with no field, but only on a definite answer from
// the app itself: a timeout or other error stays "nowhere to type", so the
// same Dictation never holds or pastes on how fast Accessibility answered.
// AXError raw values: success 0, noValue -25212, cannotComplete -25204 (a timeout),
// failure -25200, apiDisabled -25211.
@Test(arguments: [(Int32(-25212), Int32?(42)), (0, 42), (-25204, nil), (-25200, nil), (-25211, nil)])
func theFrontmostAppStandsInOnlyWhenItAnswersAboutItsFocus(_ answer: Int32, _ expected: Int32?) {
    #expect(Focus.standIn(frontmost: 42, focusedElementError: answer) == expected)
}

@Test func withNoFrontmostAppNothingStandsIn() {
    #expect(Focus.standIn(frontmost: nil, focusedElementError: -25212) == nil)
}
