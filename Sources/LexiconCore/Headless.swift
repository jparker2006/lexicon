import Foundation
public import LexiconDomain
import AudioCapture
public import Transcription
import Cleanup
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

    /// `cloud`: real providers, used only when `preferences` name a cloud model
    /// and the environment holds its key; tests pass a scripted link.
    /// `clock` times the race deadline and the local model's idle unload; tests pass a fake one.
    public static func make(paths: AppPaths, context: AppContext, preferences: Preferences,
                            local: (any LocalTranscriber)?, cloud: CloudLink = .network,
                            clock: any Clock<Duration> = ContinuousClock()) throws -> HeadlessSystem {
        let history = try HistoryStore(paths: paths)
        let conductor = Conductor(
            recorder: Recorder(), speech: SpeechEngine(local: local, cloud: cloud, clock: clock), cleanup: Cleanup(),
            lexicon: try Lexicon(paths: paths), history: history, destination: HeadlessDestination(context: context),
            preferences: PreferencesStore(fixed: preferences), secrets: Secrets(.environment),
            keyboard: nil, fixes: nil, jev: nil)
        return HeadlessSystem(conductor: conductor, history: history)
    }

    init(conductor: Conductor<HeadlessDestination>, history: HistoryStore) {
        self.conductor = conductor
        self.history = history
    }
}

/// A stand-in for the local model that always hears `text`: package tests and
/// `lexicon-eval --scripted` run the whole pipeline with no model installed.
public actor ScriptedTranscriber: LocalTranscriber {
    public nonisolated let model = LocalModel.parakeetUnified
    let text: String
    /// Every clip it was asked to transcribe, in order.
    public private(set) var heard: [AudioClip] = []

    public init(text: String) { self.text = text }

    public var isResident: Bool { true }
    public func load() {}
    public func unload() {}
    public func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) -> String {
        heard.append(clip)
        return text
    }
}
