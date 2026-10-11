import Testing
@testable import AppText

// Virtual key codes: 9 is the ANSI V key, 47 the ANSI period key.
@MainActor @Test(arguments: [
    ("com.apple.keylayout.US", UInt16(9)),
    ("com.apple.keylayout.French", 9),
    // Dvorak's V is QWERTY's period key.
    ("com.apple.keylayout.Dvorak", 47),
    // Dvorak while typing, QWERTY while Command is held.
    ("com.apple.keylayout.DVORAK-QWERTYCMD", 9),
])
func cmdVIsTheKeyThatTypesVWithCommandOnTheLayout(id: String, expected: UInt16) {
    #expect(PasteKey.keyCode(for: "v", layoutID: id) == expected)
}

@MainActor @Test func theCurrentLayoutHasACmdV() {
    #expect(PasteKey.current() != nil)
}
