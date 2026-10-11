import AppKit
import ApplicationServices
public import LexiconDomain
public import KeyInput

/// Everything Lexicon does to text inside other apps: insert, find again, read,
/// watch, replace (#7, #13).
///
/// Hides: the paste path (pasteboard promise, the target's read as a receipt,
/// restore after 200 ms of no reads guarded by `changeCount`, 8 s cap,
/// transient/concealed pasteboard markers, the physical key for "v" on the
/// current layout), focus checks, AX messaging timeouts, turning on
/// Electron accessibility (`AXManualAccessibility`) as each app activates,
/// re-looking-up elements, secure-field skipping, and the per-terminal
/// replace strategies (Terminal.app arrows + Backspace, iTerm2 select-then-
/// replace, Ghostty only when nothing was typed since).
///
/// AX element references never leave this actor. Callers name text by
/// `DictationID`; this actor remembers where each recent Dictation landed (in
/// memory). The durable key is the `InsertionReceipt` that `insert` returns,
/// which History stores; `reattach` re-finds a field from it after a restart.
///
/// Runs on its own thread with a run loop (AX observers need one, and a hung
/// target app must stall this thread, never the main thread or the Conductor).
public actor TargetApp: TextDestination {
    let executor: RunLoopExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    let input: InputClock
    private let ownPID = getpid()
    /// `nonisolated(unsafe)`: assigned once in `init` before `self` is shared,
    /// then read only by `deinit`.
    private nonisolated(unsafe) var activations: (any NSObjectProtocol)?

    /// Lexicon's own work in the latest insert, from the call to Cmd-V sent
    /// (the focus check, the pasteboard write, the key). Budget: 10 ms.
    public private(set) var lastPasteWork: Duration?

    public init(input: InputClock) {
        executor = RunLoopExecutor(name: "lexicon.ax")
        self.input = input
        // Electron apps (Claude desktop) build their accessibility tree only when
        // asked. Asking as each app activates, not at fn-up, gives the tree time
        // to exist before the focus check reads it.
        activations = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { await self?.enableAccessibility(pid) }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            Task { await self.enableAccessibility(frontmost) }
        }
    }

    deinit {
        if let activations { NSWorkspace.shared.notificationCenter.removeObserver(activations) }
    }

    private func enableAccessibility(_ pid: pid_t) {
        guard pid != ownPID else { return }
        // Apps that are not Electron answer "unsupported"; nothing to undo either way.
        _ = AXUIElementSetAttributeValue(AX.app(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Opaque, minted only here, only from the live focus at stop time.
    public struct Target: Sendable {
        let focus: FocusSnapshot
        let bundleID: String?
        let mark: InputMark
        let capturedAt: HostTime
        let field: FieldRef?
        /// What the receipt stores (`Focus.durableFingerprint`).
        let fingerprint: String?
        /// Where the paste will start: the caret, or the selection it replaces.
        let pasteStart: Int?
    }

    public func context() -> AppContext {
        guard let focus = Focus.now() else { return .unknown }
        let app = NSRunningApplication(processIdentifier: focus.pid)
        let window = AX.element(focus.app, kAXFocusedWindowAttribute)
        return AppContext(bundleID: app?.bundleIdentifier, appName: app?.localizedName,
                          windowTitle: window.flatMap { AX.string($0, kAXTitleAttribute) }, workingDirectory: nil)
    }

    public func target() async -> Target? {
        let mark = input.mark()
        guard let focus = Focus.now() else { return nil }
        // A password field never gets a Dictation, in any mode, and a link or button
        // takes none. An app that exposes no focused element at all gets the paste.
        if let traits = focus.traits, FieldTraits.accepts(traits) != .text { return nil }
        let bundleID = NSRunningApplication(processIdentifier: focus.pid)?.bundleIdentifier
        let fingerprint = focus.durableFingerprint(bundleID: bundleID)
        await Paster.shared.prefetch()  // Jake's clipboard, read now, off the text-ready-to-Cmd-V path
        return Target(focus: focus.snapshot(durable: fingerprint), bundleID: bundleID, mark: mark,
                      capturedAt: .now(), field: focus.field.map(FieldRef.init), fingerprint: fingerprint,
                      pasteStart: focus.field.flatMap { AX.range($0, kAXSelectedTextRangeAttribute)?.location })
    }

    public func insert(_ text: String, for id: DictationID, at target: Target) async -> Delivery {
        let start = ContinuousClock.now
        let now = Focus.now()
        // The same element as at fn-up keeps fn-up's snapshot; anything else differs from it.
        let focusNow = now.map { now in
            now.pid == target.focus.pid && Self.same(now.field, target.field?.element) ? target.focus
                : now.snapshot(durable: nil)
        }
        switch InsertGuard.decide(target: target.focus, focusNow: focusNow, inputSinceMark: input.hasInput(since: target.mark)) {
        case .hold(let reason):
            return .notInserted(reason)
        case .insert:
            break
        }
        guard let paste = await Paster.shared.paste(text) else { return .notInserted(.pasteFailed) }
        lastPasteWork = ContinuousClock.now - start
        // A paste with no read is not reported as typed: the text waits for paste-last.
        guard await Paster.shared.receipt(paste), let now else { return .notInserted(.pasteFailed) }
        await caretPassed(target.pasteStart.map { $0 + text.utf16.count }, in: now.field)
        return .inserted(now.receipt(inserted: text, bundleID: target.bundleID, fingerprint: target.fingerprint))
    }

    /// Electron apps update the field a frame or more after they read the
    /// pasteboard, so a caret read at once is from before the paste. Waits, up
    /// to 100 ms, for the caret to reach the end of the new text.
    private func caretPassed(_ end: Int?, in field: AXUIElement?) async {
        guard let end, let field else { return }
        let deadline = ContinuousClock.now + .milliseconds(100)
        while let caret = AX.range(field, kAXSelectedTextRangeAttribute)?.location, caret < end,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): CFEqual(a, b)
        default: false
        }
    }

    /// After a restart (no live placement for `id`): find the field again from
    /// the durable receipt History kept (fingerprint, then context around the
    /// caret). True when the placement is live again for read/watch/replace.
    public func reattach(_ id: DictationID, receipt: InsertionReceipt) -> Bool { fatalError("not implemented") }

    // MARK: Finding text again (Fixes)

    /// The field a recent Dictation landed in, read now. nil if gone or unreadable.
    public func read(_ id: DictationID) -> FieldText? { fatalError("not implemented") }

    /// Value and focus changes of that field for `window` (Hand fix watch: #13).
    /// Ends early when focus leaves or the field clears; yields the last
    /// non-empty value seen before that.
    public func watch(_ id: DictationID, for window: Duration) -> AsyncStream<FieldText> {
        fatalError("not implemented")
    }

    /// Replaces a span of a recent Dictation's text (Re-speak fix, close calls).
    /// Picks the strategy for the target app; refuses (false) when it cannot be
    /// done safely (Claude Code collapsed paste, Ghostty after typing).
    public func replace(_ span: TextSpan, in id: DictationID, with text: String) async -> Bool {
        fatalError("not implemented")
    }

    /// "I just fixed this": the focused field (or its selection) right now.
    public func readFocused() -> FieldText? { fatalError("not implemented") }
}

/// Text read from another app's field. Offsets are UTF-16, like AX.
public struct FieldText: Sendable, Hashable {
    public let text: String
    public let selection: TextSpan?
    /// Where the Dictation's text sits now, if it can still be located.
    public let dictationSpan: TextSpan?
    public let app: AppContext
}

public struct TextSpan: Sendable, Hashable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}
