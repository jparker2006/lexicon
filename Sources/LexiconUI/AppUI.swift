import AppKit
import LexiconDomain
import History
public import LexiconCore

/// Every surface Jake sees, all AppKit, all on the main actor. No SwiftUI, no
/// web views: one UI framework, so the nearest example a builder copies is
/// always the right kind (ADR 0002).
///
/// The UI never decides what happens to a Dictation. It renders
/// `ConductorEvent`s and History rows, and sends commands back:
/// `conductor.retry`, `conductor.pasteLast`, `history.record(.pinned/.deleted)`,
/// `preferences.update`.
@MainActor
public final class AppUI {
    public init(system: LexiconSystem, prompter: FixPromptPresenter) { fatalError("not implemented") }

    /// Status item and the (hidden) indicator panel: `DictationIndicator.follow`
    /// with `conductor.events()` and `recorder.levels`.
    public func start() { fatalError("not implemented") }

    public func showSettings() { fatalError("not implemented") }
}
