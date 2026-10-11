import AppKit

/// The one owner of the general pasteboard during a paste: puts the text up,
/// sends Cmd-V, and runs the restore timer. Main actor, because pasteboard
/// promise callbacks arrive on the main run loop.
@MainActor final class Paster {
    static let shared = Paster()

    private let keeper = ClipboardKeeper(pasteboard: SystemPasteboard())
    private var timer: Task<Void, Never>?
    private var latest: ClipboardKeeper.PasteID?

    private init() {
        keeper.onRead = { [unowned self] in schedule() }
    }

    /// Reads Jake's clipboard ahead of the paste (fn-up).
    func prefetch() {
        keeper.prefetch()
        schedule()
    }

    /// Puts `text` up and sends Cmd-V. nil when no Cmd-V key or event could be
    /// made; then the pasteboard is untouched. Waits first while an earlier
    /// paste is unread (paste-last does not take a Dictation's insert turn), so
    /// its queued Cmd-V never pastes this text.
    func paste(_ text: String) async -> ClipboardKeeper.PasteID? {
        while let unread = latest, !keeper.isReleased(unread) { await keeper.released(unread) }
        guard let code = PasteKey.current(), let chord = PasteKey.Chord(code) else { return nil }
        let id = keeper.put(text)
        latest = id
        chord.post()
        schedule()
        return id
    }

    func receipt(_ id: ClipboardKeeper.PasteID) async -> Bool { await keeper.receipt(id) }

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
