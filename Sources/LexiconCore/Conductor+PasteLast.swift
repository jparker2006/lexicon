import LexiconDomain
import History

// ⌃⌘V: the newest Dictation with text, pasted at the focus now.

extension Conductor {
    /// ⌃⌘V: the final text of the newest Dictation that has text, at the current focus.
    /// Same insert path as a live Dictation (target captured now).
    public func pasteLast() async {
        guard let newest = await history.newestText() else { return emit(.notice(.nothingToPaste)) }
        guard let target = await destination.target() else { return emit(.notice(.noFieldToPaste)) }
        switch await destination.pasteLast(newest.text, for: newest.id, at: target) {
        case .inserted(let receipt):
            history.record(.delivered(newest.id, receipt, lag: nil))
            emit(.pasted(newest.id, newerOnItsWay: newest.newerOnItsWay))
        case .notInserted, .historyOnly:
            // Nothing took it: the row keeps its status, and Jake is told where to click to press again.
            emit(.notice(.noFieldToPaste))
        }
    }
}
