import AppKit
import ApplicationServices
import LexiconDomain

// Re-speak (M4): read the field a Re-speak's own target names, then paste over
// one span of it through the same lane, clipboard restore and late-text guard
// as an insert. Terminals get their own paths in #84.

extension TargetApp {
    /// Terminals keep no selectable text field; #84 gives each its own path.
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"]
    /// A field longer than this (a log, a whole document) is not read whole.
    static let readCap = 200_000
    /// Where an app shows an embedded object (an image, a paste chip) in its text.
    static let embeddedObject: Character = "\u{FFFC}"

    public func read(at target: Target) async -> FieldText? {
        guard let field = target.field?.element else { return nil }
        // Electron builds its accessibility tree late: a first read can fail where a
        // second one 20 ms later answers. Up to 100 ms, and only after a failure.
        var text = Self.value(of: field)
        for _ in 0..<5 where text == nil {
            try? await Task.sleep(for: .milliseconds(20))
            text = Self.value(of: field)
        }
        guard let text else { return nil }
        return FieldText(text: text, selection: target.selection, bundleID: target.bundleID,
                         fieldFingerprint: target.fingerprint)
    }

    public func replace(_ span: TextSpan, expected: String, with text: String, at target: Target) async -> ReplaceOutcome {
        if let bundleID = target.bundleID, Self.terminals.contains(bundleID) { return .refused(.terminal) }
        guard let ref = target.field else { return .refused(.noField) }
        let field = ref.element
        // An embedded object counts as one character in some apps and none in others,
        // so offsets past one can't be trusted.
        guard !expected.isEmpty, !expected.contains(Self.embeddedObject), !text.contains(Self.embeddedObject) else {
            return .refused(.cannotSelect)
        }
        // Nothing is selected in a field Jake has left.
        if case .hold(let reason) = check(target).0 { return .refused(ReplaceRefusal(reason)) }
        // The selection is proved by the text it holds, not by the range read back:
        // Chromium applies a new selection a moment later, and some apps ignore it.
        if !Self.selection(of: field, is: span, reading: expected) {
            guard AX.select(span, in: field) else { return .refused(.cannotSelect) }
            let deadline = ContinuousClock.now + .milliseconds(50)
            while !Self.selection(of: field, is: span, reading: expected) {
                guard ContinuousClock.now < deadline else {
                    return AX.string(field, in: span.cfRange) == expected ? .refused(.cannotSelect) : .refused(.textChanged)
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        var selectionLost = false
        let order = await PasteOrder.run(text, as: .dictation, lane: Paster.shared) {
            let (decision, now) = check(target)
            guard case .insert = decision else { return (decision, now) }
            // Checked again right before Cmd-V, and on every try after a busy lane.
            selectionLost = !Self.selection(of: ref.element, is: span, reading: expected)
            return (selectionLost ? .hold(.focusMoved) : .insert, now)
        }
        let paste: ClipboardKeeper.PasteID
        switch order {
        case .held(let reason):
            return .refused(selectionLost ? .textChanged : ReplaceRefusal(reason))
        case .failed: return .refused(.pasteFailed)
        case .sent(let id, _, _): paste = id
        }
        let sentMark = input.mark()
        guard await Paster.shared.receipt(paste) else { return .refused(.pasteFailed) }
        let end = span.location + text.utf16.count
        await caretPassed(end, in: field)
        guard AX.string(field, in: CFRange(location: span.location, length: text.utf16.count)) == text else {
            return .unverified
        }
        // Read before the caret goes back: the receipt's caret is the end of the new words.
        let receipt = Focus(pid: target.focus.pid, app: AX.app(target.focus.pid), field: field)
            .receipt(inserted: text, bundleID: target.bundleID, fingerprint: target.fingerprint)
        // A fix found by sound: put the caret back where Jake left it, past the
        // fixed words, once, and never while he is typing again.
        if target.selection?.span != span, let caret = target.pasteStart, caret >= span.location + span.length,
           !input.hasInput(since: sentMark) {
            _ = AX.select(TextSpan(location: caret + text.utf16.count - span.length, length: 0), in: field)
        }
        return .replaced(receipt)
    }

    /// The whole value, or nil past `readCap` or when the app doesn't answer.
    private static func value(of field: AXUIElement) -> String? {
        if let count = AX.int(field, kAXNumberOfCharactersAttribute), count > readCap { return nil }
        guard let value = AX.string(field, kAXValueAttribute), value.utf16.count <= readCap else { return nil }
        return value
    }

    private static func selection(of field: AXUIElement, is span: TextSpan, reading expected: String) -> Bool {
        guard let range = AX.range(field, kAXSelectedTextRangeAttribute),
              range.location == span.location, range.length == span.length else { return false }
        return AX.string(field, kAXSelectedTextAttribute) == expected
    }
}

extension ReplaceRefusal {
    init(_ reason: NotInsertedReason) {
        self = switch reason {
        case .noField: .noField
        case .focusMoved: .focusMoved
        case .typedSince: .typedSince
        case .tooLate: .tooLate
        case .clipboardDenied: .clipboardDenied
        case .pasteFailed, .interrupted: .pasteFailed
        }
    }
}

extension TextSpan {
    var cfRange: CFRange { CFRange(location: location, length: length) }
}
