import AppKit
import LexiconDomain
import History
public import LexiconCore

/// Every surface Jake sees, all AppKit, all on the main actor. No SwiftUI, no
/// web views: one UI framework, so the nearest example a builder copies is
/// always the right kind (see design.md for the number that would change this).
///
/// The UI never decides what happens to a Dictation. It renders
/// `ConductorEvent`s and History rows, and sends commands back:
/// `conductor.retry`, `conductor.pasteLast`, `history.record(.pinned/.deleted)`,
/// `preferences.update`.
@MainActor
public final class AppUI {
    public init(system: LexiconSystem, prompter: FixPromptPresenter) { fatalError("not implemented") }

    /// Status item and the (hidden) indicator panel. Subscribes to conductor events.
    public func start() { fatalError("not implemented") }

    /// Menu bar click, and reopen from Spotlight/Finder. Under 100 ms to first
    /// rows. Creates the window each time; closing releases it and its
    /// History connection (closed, not hidden: #4).
    public func showHistory() { fatalError("not implemented") }

    public func showSettings() { fatalError("not implemented") }
}

/// The Dictation indicator: a borderless NSPanel with `.nonactivatingPanel`,
/// `ignoresMouseEvents`, `canBecomeKey == false`, joins all Spaces and full-screen
/// apps. It must never take focus: focus is where the text will be pasted.
/// Drawn with one CALayer-backed view (level meter from `Recorder.levels`).
/// Look and placement are #18's.
@MainActor
final class DictationIndicator {
    let panel: NSPanel
    init() { fatalError("not implemented") }
    func render(_ event: ConductorEvent) { fatalError("not implemented") }
}
