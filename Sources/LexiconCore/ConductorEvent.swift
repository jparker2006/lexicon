public import LexiconDomain

/// What the UI shows. The ONE list of things the indicator, status item and
/// notices react to; the UI switches over it exhaustively.
public enum ConductorEvent: Sendable {
    case started(DictationID)
    /// First real audio arrived: show "listening" now (#4).
    case listening(DictationID)
    case confirmed(DictationID, DictationMode)
    /// The 19-minute mark: one minute until the cap stops the Dictation. (#58 emits it.)
    case oneMinuteLeft(DictationID)
    /// fn-up, Esc or sleep ended the recording. Not sent for a discarded tap, which was never confirmed.
    case stopped(DictationID)
    case transcribing(DictationID)
    case finished(DictationID, DictationStatus)
    case notice(Notice)
}

public enum Notice: Sendable, Hashable {
    /// Text ready but not typed: "Dictation ready, paste-last to insert" (#4).
    case readyToPaste(DictationID)
    case waitingForNetwork(DictationID)
    /// A Dictation the last run left unfinished has its text, at the top of History, never typed (#4).
    case recovered(DictationID)
    case microphoneUnavailable(String)
    case microphoneSilent
    case microphoneMuted
    case diskTrouble
    case accessibilityNeeded
    case nothingToPaste
    case noFieldToPaste
    /// A Re-speak fix changed nothing, or Lexicon can't vouch for it.
    case fixNotLanded(FixProblem)
}

/// Why a Re-speak fix didn't land, in the words the indicator uses.
public enum FixProblem: Sendable, Hashable, CaseIterable {
    /// Jake moved to another field, typed or clicked, or it came too late.
    case movedOn
    /// The text changed since it was selected.
    case textChanged
    /// The app would not let Lexicon select the text.
    case cannotSelect
    /// No terminal path yet (#84); a collapsed paste can't be reached either.
    case terminal
    case noField
    /// "Paste from Other Apps" is denied, so Lexicon can't save Jake's clipboard.
    case clipboardDenied
    case pasteFailed
    /// Cmd-V went out, but the field doesn't show the fix where it belongs.
    case unverified
    /// The fix landed in the app, but History couldn't be read to save it.
    case historyUnreadable
    /// The Re-speak held no word to put in.
    case nothingHeard
}
