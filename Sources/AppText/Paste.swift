import AppKit
import os
import KeyInput

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

    /// The longest a ⌃⌘V paste waits for Jake to let go of the keys.
    static let keysWait: Duration = .seconds(1)
    private let log = Logger(subsystem: "Lexicon", category: "paste")

    /// ⌃⌘V: returns once no modifier and neither the hotkey's key nor the layout's "v"
    /// is down (polled every 10 ms), or after `keysWait`, and logs how long it took.
    func keysReleased() async {
        let start = ContinuousClock.now
        while Self.keysDown(), ContinuousClock.now - start < Self.keysWait {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let waited = (ContinuousClock.now - start) / .milliseconds(1)
        if Self.keysDown() {
            log.notice("paste-last: keys still down after \(Int(waited), privacy: .public) ms; pasting anyway")
        } else {
            log.notice("paste-last: keys up after \(Int(waited), privacy: .public) ms")
        }
    }

    private static func keysDown() -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        if !CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty { return true }
        let keys = [CGKeyCode(KeyboardConfig().pasteLast.keyCode), PasteKey.current()].compactMap { $0 }
        return keys.contains { CGEventSource.keyState(.hidSystemState, key: $0) }
    }

    /// Quit: Jake's clipboard back before Lexicon exits. At most `missedHold` per
    /// paste, the longest a missed paste's text stays up.
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
