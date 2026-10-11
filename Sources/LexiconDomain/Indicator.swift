/// What the recording pill and the menu bar icon show. LexiconUI derives it
/// from the Conductor's events; test hooks set it directly.
public enum IndicatorState: Sendable, Hashable, Codable {
    case hidden
    /// Red dot and live level bars; hands-free adds the lock and "Tap fn to stop".
    case recording(DictationMode, minuteLeft: Bool)
    /// fn is up: the bars settle into grey dots while the text is made.
    case finishing
    /// The text was typed: a check, gone by about 0.45 s.
    case landed
    /// The text is ready but nothing took it: "Not typed. Press ⌃⌘V to paste it."
    case pasteLast
    /// The line the pill shows.
    case error(String)
}

/// The sounds Lexicon makes. Paste-last reuses `error`, and there is no landed
/// sound: the stop sound already marks the end.
public enum SoundCue: String, Sendable, Hashable, Codable, CaseIterable {
    case start
    case stop
    case warning
    case error
}
