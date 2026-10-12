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

// An app that is in front but answers no Accessibility focus (#60 Live checks:
// a key window with no focused element read as "nowhere to type") is still the
// app Cmd-V reaches, so the fieldless 5 s rule applies to it.
@Test func theFrontmostAppStandsInWhenAccessibilityNamesNoFocusedApp() {
    #expect(Focus.focusedPID(accessibility: nil, frontmost: 42) == 42)
    #expect(Focus.focusedPID(accessibility: 7, frontmost: 42) == 7)
    #expect(Focus.focusedPID(accessibility: nil, frontmost: nil) == nil)
}
