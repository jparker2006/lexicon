import AppKit

/// The one owner of the general pasteboard during a paste: puts the text up,
/// sends Cmd-V, and runs the restore timer. Main actor, because pasteboard
/// promise callbacks arrive on the main run loop.
@MainActor final class Paster {
    static let shared = Paster()

    private let keeper = ClipboardKeeper(pasteboard: SystemPasteboard())
    private var timer: Task<Void, Never>?

    private init() {
        keeper.onRead = { [unowned self] in schedule() }
    }

    /// Reads Jake's clipboard ahead of the paste (fn-up).
    func prefetch() { keeper.prefetch() }

    /// Puts `text` up and sends Cmd-V. nil when no Cmd-V key or event could be
    /// made; then the pasteboard is untouched.
    func paste(_ text: String) -> ClipboardKeeper.PasteID? {
        guard let code = PasteKey.current(), let chord = PasteKey.Chord(code) else { return nil }
        let id = keeper.put(text)
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
