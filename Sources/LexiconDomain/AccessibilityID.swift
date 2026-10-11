/// Accessibility identifiers on Lexicon's own surfaces. `lexicon-harness` finds
/// them by these, so the app and the harness name each one in one place.
public enum AccessibilityID {
    /// The History window, its table of Dictations and its search field.
    public static let historyWindow = "lexicon.history"
    public static let historyTable = "lexicon.history.table"
    public static let historySearch = "lexicon.history.search"
    /// Each History row's buttons: play, the Test set pin and the ⋯ menu.
    public static let historyPlay = "lexicon.history.play"
    public static let historyPin = "lexicon.history.pin"
    public static let historyMore = "lexicon.history.more"
    /// The menu bar icon's button.
    public static let statusItem = "lexicon.statusItem"
    /// The recording pill's panel.
    public static let indicator = "lexicon.indicator"
}
