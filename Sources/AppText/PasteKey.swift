import Carbon
import CoreGraphics

/// Cmd-V as a physical key: whichever key types "v" with Command held on the
/// current layout (Dvorak puts it elsewhere; "Dvorak - QWERTY ⌘" keeps it on
/// QWERTY's V), else the ASCII-capable layout under an input method. Resolved
/// on every paste, so switching layouts mid-Dictation can't leave a stale key.
///
/// The layout inversion is adapted from Muesli's PasteShortcut.swift
/// (github.com/Muesli-HQ/muesli), MIT License, Copyright (c) 2026 Pranav Hari;
/// the full notice is at the end of this file.
enum PasteKey {
    /// TIS must run on the main thread.
    @MainActor static func current() -> CGKeyCode? {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let code = keyCode(for: "v", in: source) {
            return code
        }
        guard let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return keyCode(for: "v", in: ascii)
    }

    /// The key that types `character` with Command held on `source`'s layout.
    static func keyCode(for character: String, in source: TISInputSource) -> CGKeyCode? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let command = UInt32((cmdKey >> 8) & 0xff)
        for code in UInt16(0)..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), command, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                        characters.count, &length, &characters)
            if status == noErr, length > 0,
               String(utf16CodeUnits: characters, count: length).caseInsensitiveCompare(character) == .orderedSame {
                return code
            }
        }
        return nil
    }

    /// Cmd-V on `code`, made before the pasteboard is touched so that nothing
    /// can fail between the write and the keys. The flags are set outright, so
    /// a fn (or ⌃) still held, as when a hands-free stop is a fn-down, never
    /// reaches the target as part of the chord.
    struct Chord {
        let down: CGEvent
        let up: CGEvent

        init?(_ code: CGKeyCode) {
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return nil }
            down.flags = .maskCommand
            up.flags = .maskCommand
            self.down = down
            self.up = up
        }

        func post() {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}

// Muesli's license, for the layout inversion above:
//
// MIT License
//
// Copyright (c) 2026 Pranav Hari
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
