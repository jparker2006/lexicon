#if DEBUG
import LexiconDomain

// The CLI's names for the indicator states, and what the app must show for each.
// `hook indicator` and `pill` both go through `indicatorState(named:message:)`.

/// What `error` shows when the command gives no message.
let defaultErrorMessage = "No speech heard"

/// The one mapping from a CLI state name to what the pill shows. `message` is
/// the line for `error` and is ignored by the other states. Nil for an unknown name.
func indicatorState(named name: String, message: String? = nil) -> IndicatorState? {
    switch name {
    case "hidden": .hidden
    case "held": .recording(.hold, minuteLeft: false)
    case "handsfree": .recording(.handsFree, minuteLeft: false)
    case "warning": .recording(.hold, minuteLeft: true)
    case "finishing": .finishing
    case "landed": .landed
    case "paste": .pasteLast
    case "error": .error(message ?? defaultErrorMessage)
    default: nil
    }
}

/// What `pill` expects of one state: the text on the pill (nil when it shows
/// none) and the menu bar icon's label. The app's copy is written down here only.
struct IndicatorExpectation {
    let name: String
    let pillText: String?
    let statusLabel: String
}

/// Every state, in the order `pill` shows them. Update this table when the copy changes.
let indicatorExpectations: [IndicatorExpectation] = [
    IndicatorExpectation(name: "hidden", pillText: nil, statusLabel: "Lexicon"),
    IndicatorExpectation(name: "held", pillText: nil, statusLabel: "Lexicon: recording"),
    IndicatorExpectation(name: "handsfree", pillText: "Tap fn to stop", statusLabel: "Lexicon: recording hands-free"),
    IndicatorExpectation(name: "warning", pillText: "1 min left", statusLabel: "Lexicon: recording, 1 min left"),
    IndicatorExpectation(name: "finishing", pillText: nil, statusLabel: "Lexicon: finishing"),
    IndicatorExpectation(name: "landed", pillText: nil, statusLabel: "Lexicon: typed"),
    IndicatorExpectation(name: "paste", pillText: "Not typed. Press ⌃⌘V to paste it.", statusLabel: "Lexicon: not typed"),
    IndicatorExpectation(name: "error", pillText: defaultErrorMessage, statusLabel: "Lexicon: error"),
]
#endif
