import AppKit

/// The one owner of the general pasteboard during a paste: puts the text up,
/// sends Cmd-V, and runs the restore timer. Main actor, because pasteboard
/// promise callbacks arrive on the main run loop.
@MainActor final class Paster: PasteLane {
    static let shared = Paster()

    private let keeper = ClipboardKeeper(pasteboard: SystemPasteboard())
    private var timer: Task<Void, Never>?
    private var latest: ClipboardKeeper.PasteID?

    private init() {
        keeper.onRead = { [unowned self] in schedule() }
    }

    /// Reads Jake's clipboard ahead of the paste (fn-up).
    func prefetch() {
        guard keeper.canSave else { return }
        keeper.prefetch()
        schedule()
    }

    func idle() async {
        while let unread = latest, !keeper.isReleased(unread) { await keeper.released(unread) }
    }

    func paste(_ text: String, as kind: PasteKind) -> PasteAttempt {
        if let unread = latest, !keeper.isReleased(unread) { return .busy }
        guard let plan = keeper.plan(for: kind) else { return .denied }
        guard let code = PasteKey.current(), let chord = PasteKey.Chord(code) else { return .failed }
        let id = keeper.put(text, restoring: plan == .restore)
        latest = id
        chord.post()
        schedule()
        return .sent(id)
    }

    func receipt(_ id: ClipboardKeeper.PasteID) async -> Bool { await keeper.receipt(id) }

    /// Quit: Jake's clipboard back before Lexicon exits. At most `missedHold`,
    /// the longest a missed paste's text stays up.
    func finishForQuit() async {
        await keeper.finishForQuit(within: ClipboardKeeper.missedHold, clock: ContinuousClock())
    }

    private func schedule() {
        timer?.cancel()
        guard let deadline = keeper.deadline else { return }
        timer = Task { [unowned self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }  // rescheduled
            _ = keeper.expire(at: .now)
            schedule()
        }
    }
}
