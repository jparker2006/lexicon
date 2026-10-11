import Foundation
public import LexiconDomain
import AudioCapture
public import Transcription
import WordStore
public import History
public import AppText

/// A destination that records text instead of pasting it. Used by
/// `lexicon-eval` and package tests, so they run the real Conductor.
public actor HeadlessDestination: TextDestination {
    public struct Target: Sendable {
        let serial: Int
        let focus: FocusSnapshot
    }

    let fixedContext: AppContext
    private(set) var delivered: [DictationID: String] = [:]

    /// `context`: what the Test set entry says Jake was dictating into (#15 manifest `context`).
    public init(context: AppContext = .unknown) { self.fixedContext = context }

    public func context() -> AppContext { fixedContext }
    public func target() -> Target? {
        Target(serial: delivered.count, focus: FocusSnapshot(pid: 0, fieldFingerprint: "headless"))
    }

    /// Same guard as every insert (focus never moves and nobody types here, so it inserts).
    public func insert(_ text: String, for id: DictationID, at target: Target) -> Delivery {
        switch InsertGuard.decide(target: target.focus, focusNow: target.focus, inputSinceMark: false) {
        case .hold(let reason):
            return .notInserted(reason)
        case .insert:
            delivered[id] = text
            return .inserted(InsertionReceipt(appBundleID: fixedContext.bundleID, fieldFingerprint: "headless",
                                              caretAfter: text.utf16.count, contextBefore: "", contextAfter: "",
                                              insertedAt: Date()))
        }
    }
}

/// The same modules as `LexiconSystem` minus the keyboard, AppText, Fixes and
/// the inbox. History and the Lexicon live under a temporary `AppPaths` unless
/// a caller passes real ones (read-only use only: never point eval at Jake's History).
public final class HeadlessSystem: Sendable {
    public let conductor: Conductor<HeadlessDestination>
    public let history: HistoryStore

    public static func make(paths: AppPaths, context: AppContext, preferences: Preferences,
                            local: (any LocalTranscriber)?) throws -> HeadlessSystem {
        fatalError("not implemented")
    }

    init() { fatalError("not implemented") }
}
