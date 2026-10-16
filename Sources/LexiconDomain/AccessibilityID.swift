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
    /// The Lexicon page: its window, list, search field, Add new and Import
    /// buttons, the Add sheet's field, and each row's delete button.
    public static let lexiconWindow = "lexicon.page"
    public static let lexiconTable = "lexicon.page.table"
    public static let lexiconSearch = "lexicon.page.search"
    public static let lexiconAdd = "lexicon.page.add"
    public static let lexiconImport = "lexicon.page.import"
    public static let lexiconAddField = "lexicon.page.addField"
    public static let lexiconDelete = "lexicon.page.delete"
    public static let lexiconRemoveForm = "lexicon.page.removeForm"
    /// The menu bar icon's button.
    public static let statusItem = "lexicon.statusItem"
    /// The recording pill's panel.
    public static let indicator = "lexicon.indicator"
    /// First-run setup: its window, and the box the "Try it" step's Dictation lands in.
    public static let setupWindow = "lexicon.setup"
    public static let setupTryField = "lexicon.setup.tryField"
}
