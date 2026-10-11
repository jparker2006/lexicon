import Carbon
import Testing
@testable import AppText

/// A layout that ships with macOS, enabled or not.
private func layout(_ id: String) throws -> TISInputSource {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
    return try #require(list?.first, "\(id) is not installed")
}

@MainActor @Test(arguments: [
    ("com.apple.keylayout.US", CGKeyCode(kVK_ANSI_V)),
    ("com.apple.keylayout.French", CGKeyCode(kVK_ANSI_V)),
    // Dvorak's V is QWERTY's period key.
    ("com.apple.keylayout.Dvorak", CGKeyCode(kVK_ANSI_Period)),
    // Dvorak while typing, QWERTY while Command is held.
    ("com.apple.keylayout.DVORAK-QWERTYCMD", CGKeyCode(kVK_ANSI_V)),
])
func cmdVIsTheKeyThatTypesVWithCommandOnTheLayout(id: String, expected: CGKeyCode) throws {
    #expect(PasteKey.keyCode(for: "v", in: try layout(id)) == expected)
}

@MainActor @Test func theCurrentLayoutHasACmdV() {
    #expect(PasteKey.current() != nil)
}
