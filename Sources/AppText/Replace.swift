public import LexiconDomain

/// A run of text in a field. Offsets are UTF-16, like AX.
public struct TextSpan: Sendable, Hashable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// Text Jake had selected when the target was taken, and where.
public struct FieldSelection: Sendable, Hashable {
    public let span: TextSpan
    public let text: String
    public init(span: TextSpan, text: String) {
        self.span = span
        self.text = text
    }
}

/// A target's field, read for a Re-speak: the whole of it, or for a field too
/// long to read whole, a window of it starting at `offset`. Spans are the field's.
public struct FieldText: Sendable, Hashable {
    public let text: String
    /// Where `text` starts in the field, in UTF-16 units: 0 when it is the whole field.
    public let offset: Int
    /// What Jake had selected when the target was taken; nil when nothing was.
    public let selection: FieldSelection?
    public let bundleID: String?
    /// The target's durable fingerprint: the value an insert's receipt stores.
    public let fieldFingerprint: String?
    public init(text: String, offset: Int = 0, selection: FieldSelection?, bundleID: String?, fieldFingerprint: String?) {
        self.text = text
        self.offset = offset
        self.selection = selection
        self.bundleID = bundleID
        self.fieldFingerprint = fieldFingerprint
    }

    /// From a read window and the selection's span: the selection's text comes
    /// from the window, so no second read can disagree with it. nil when the
    /// selection runs outside the window.
    public static func reading(_ window: String, offset: Int, selection: TextSpan?, bundleID: String?,
                               fieldFingerprint: String?) -> FieldText? {
        var selected: FieldSelection?
        if let selection {
            let utf16 = window.utf16, start = selection.location - offset
            guard start >= 0, start + selection.length <= utf16.count else { return nil }
            let from = utf16.index(utf16.startIndex, offsetBy: start)
            guard let text = String(utf16[from..<utf16.index(from, offsetBy: selection.length)]) else { return nil }
            selected = FieldSelection(span: selection, text: text)
        }
        return FieldText(text: window, offset: offset, selection: selected, bundleID: bundleID,
                         fieldFingerprint: fieldFingerprint)
    }
}

/// Which part of a long field a Re-speak reads. Pure.
enum FieldWindow {
    /// At most `cap` UTF-16 units of a field `count` long, holding `anchor`
    /// (the selection or the caret) and as much before it as fits.
    static func span(count: Int, around anchor: Int, cap: Int) -> TextSpan {
        guard count > cap else { return TextSpan(location: 0, length: count) }
        // A little past the anchor, for the words after the caret; the rest before it.
        let start = max(0, min(count, anchor + 2_000) - cap)
        return TextSpan(location: start, length: min(cap, count - start))
    }
}

/// What a replace did. Only `replaced` changed the field where it was asked to.
public enum ReplaceOutcome: Sendable, Hashable {
    /// Where the new words landed, as an insert's receipt says it.
    case replaced(InsertionReceipt)
    /// Cmd-V went out and was read, but the field doesn't show the new text at the span.
    case unverified
    case refused(ReplaceRefusal)
}

/// Why a replace changed nothing.
public enum ReplaceRefusal: String, Sendable, Hashable, CaseIterable {
    case noField
    case focusMoved
    case typedSince
    case tooLate
    /// The span no longer reads what it did.
    case textChanged
    /// The app would not select the span.
    case cannotSelect
    /// Terminals get their own paths (#84).
    case terminal
    case clipboardDenied
    case pasteFailed
}

/// Where a Dictation's text sits in a field now. Pure; offsets are UTF-16.
public enum DictationPlace {
    /// nil unless the field is the one the receipt names: the same words in
    /// another field are not that Dictation. Where it was pasted, if it is still
    /// there; else, if Jake typed before it, the copy that follows the words the
    /// receipt saw before it, nearest the old caret.
    public static func locate(_ text: String, receipt: InsertionReceipt, in field: FieldText) -> TextSpan? {
        guard let fingerprint = receipt.fieldFingerprint, fingerprint == field.fieldFingerprint,
              receipt.appBundleID == field.bundleID, !text.isEmpty else { return nil }
        let haystack = Array(field.text.utf16), needle = Array(text.utf16), context = Array(receipt.contextBefore.utf16)
        let starts = haystack.count < needle.count ? [] : (0...(haystack.count - needle.count)).filter { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
        let caret = receipt.caretAfter.map { $0 - field.offset }
        if let caret, starts.contains(caret - needle.count) {
            return TextSpan(location: field.offset + caret - needle.count, length: needle.count)
        }
        let followsContext = starts.filter { start in
            start >= context.count && haystack[(start - context.count)..<start].elementsEqual(context)
        }
        let end = caret ?? 0
        return followsContext.min { abs($0 + needle.count - end) < abs($1 + needle.count - end) }
            .map { TextSpan(location: field.offset + $0, length: needle.count) }
    }
}
