import LexiconDomain

/// The text a Re-speak puts over the words it fixes. Pure.
enum RespeakText {
    /// `spoken`: the Re-speak's cleaned text. `before`: the words it replaces.
    static func replacement(_ spoken: String, replacing before: String) -> String {
        spoken
    }
}
