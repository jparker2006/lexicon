import AppKit
import LexiconDomain
public import Fixes

/// "Always fix it this way?" UI. Created before the system (FixEngine needs a
/// prompter at construction), so it is the one UI type that is Sendable.
/// The form (toast with Undo, review list, question) is #24's prototype;
/// whichever wins lives behind this one method.
public final class FixPromptPresenter: FixPrompter {
    public init() {}

    public func propose(_ proposal: RuleProposal) async -> RuleAnswer {
        // TODO: hop to the main actor, show the non-activating panel/toast, await Jake's answer
        // or a timeout (timeout = .notThisTime). Never steals focus.
        fatalError("not implemented")
    }
}
