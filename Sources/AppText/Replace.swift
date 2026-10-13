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

/// A target's field, read for a Re-speak.
public struct FieldText: Sendable, Hashable {
    public let text: String
    /// What Jake had selected when the target was taken; nil when nothing was.
    public let selection: FieldSelection?
    public let bundleID: String?
    /// The target's durable fingerprint: the value an insert's receipt stores.
    public let fieldFingerprint: String?
    public init(text: String, selection: FieldSelection?, bundleID: String?, fieldFingerprint: String?) {
        self.text = text
        self.selection = selection
        self.bundleID = bundleID
        self.fieldFingerprint = fieldFingerprint
    }
}

/// What a replace did. Only `replaced` changed the field where it was asked to.
public enum ReplaceOutcome: Sendable, Hashable {
    case replaced
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

/// Where a Dictation's text sits in a field now. Pure.
public enum DictationPlace {
    /// nil unless the field is the one the receipt names.
    public static func locate(_ text: String, receipt: InsertionReceipt, in field: FieldText) -> TextSpan? {
        nil
    }
}
