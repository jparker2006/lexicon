import LexiconDomain
import History

// ⌃⌘V: the newest Dictation with text, pasted at the focus now.

extension Conductor {
    /// ⌃⌘V: the final text of the newest Dictation that has text, at the current focus.
    /// Same insert path as a live Dictation (target captured now).
    public func pasteLast() async {
        guard let (id, text) = await history.newestText() else { return emit(.notice(.nothingToPaste)) }
        guard let target = await destination.target() else { return emit(.notice(.noFieldToPaste)) }
        switch await destination.pasteLast(text, for: id, at: target) {
        case .inserted(let receipt): history.record(.delivered(id, receipt, lag: nil))
        case .notInserted, .historyOnly: break  // the row keeps its status; Jake can press it again
        }
    }
}
