import os
import LexiconDomain
import History

// ⌃⌘V: the newest Dictation with text, pasted at the focus now.

extension Conductor {
    /// ⌃⌘V: the final text of the newest Dictation that has text, at the current focus.
    /// Same insert path as a live Dictation (target captured now). Each outcome leaves a
    /// log line naming its branch (never the text), so a press that pastes nothing says why.
    public func pasteLast() async {
        guard let newest = await history.newestText() else {
            log.notice("paste-last: nothing to paste")
            return emit(.notice(.nothingToPaste))
        }
        // The hotkey can repeat while held. Its repeats precede this paste's mark,
        // and waiting for release does not spend the fieldless paste window.
        await destination.prepareForPasteLast()
        guard let target = await destination.target() else {
            log.notice("paste-last \(newest.id, privacy: .public): no target")
            return emit(.notice(.noFieldToPaste))
        }
        switch await destination.pasteLast(newest.text, for: newest.id, at: target) {
        case .inserted(let receipt):
            log.notice("paste-last \(newest.id, privacy: .public): inserted")
            history.record(.delivered(newest.id, receipt, lag: nil))
            emit(.pasted(newest.id, newerOnItsWay: newest.newerOnItsWay))
        case .notInserted(let reason):
            // Nothing took it: the row keeps its status, and Jake is told where to click to press again.
            log.notice("paste-last \(newest.id, privacy: .public): held, \(reason.rawValue, privacy: .public)")
            emit(.notice(.noFieldToPaste))
        case .historyOnly:
            log.notice("paste-last \(newest.id, privacy: .public): not pasted")
            emit(.notice(.noFieldToPaste))
        }
    }
}
