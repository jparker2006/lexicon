/// Re-speak's candidate finder (M4): which span of the recent text did Jake
/// just say again? Every span of 1 to 3 words, ranked by how much it sounds
/// like the re-spoken words. Pure and local: Private mode picks from this
/// ranking alone, and Jev is sent only its first few.
public enum CandidateFinder {
    /// Every span of 1 to 3 words in `recent` (split on whitespace), best
    /// sounding first. Ties go to the span nearer the end, where the caret is.
    /// Punctuation at a span's edges is not part of it: replacing "super base."
    /// keeps the period.
    public static func candidates(for spoken: String, in recent: String) -> [SpanCandidate] {
        []
    }
}

/// One span of the recent text a Re-speak might replace.
public struct SpanCandidate: Sendable, Hashable {
    /// Word indexes into the recent text, split on whitespace (as Jev counts them).
    public let words: Range<Int>
    /// The span as written, without the punctuation at its edges.
    public let text: String
    /// Where `text` sits in the recent text, in UTF-16 offsets, for the replace.
    public let utf16: Range<Int>
    /// `Phonetic.code(text)`: Jev reads text only, so it gets the sound as text too.
    public let phonetic: String
    /// 0 sounds the same as the re-spoken words, 1 nothing alike.
    public let distance: Double

    public init(words: Range<Int>, text: String, utf16: Range<Int>, phonetic: String, distance: Double) {
        self.words = words
        self.text = text
        self.utf16 = utf16
        self.phonetic = phonetic
        self.distance = distance
    }
}

/// A rough English sound code: consonant sounds, spaces and case ignored.
public enum Phonetic {
    public static func code(_ text: String) -> String { "" }
}
