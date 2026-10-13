import Foundation
public import LexiconDomain
import AudioCapture
public import Transcription
import Cleanup
public import WordStore
public import History
public import AppText

/// A destination that records text instead of pasting it. Used by
/// `lexicon-eval` and package tests, so they run the real Conductor.
public actor HeadlessDestination: TextDestination {
    public struct Target: Sendable {
        let serial: Int
        let focus: FocusSnapshot
        let selection: TextSpan?
    }

    private var current: AppContext
    private var focusWatchers: [UUID: AsyncStream<AppContext>.Continuation] = [:]
    private(set) var delivered: [DictationID: String] = [:]
    /// Every Dictation typed, in the order it was typed.
    private(set) var typedOrder: [DictationID] = []
    /// One field, as if Jake stayed in it: every Dictation is typed at its end.
    public private(set) var fieldText = ""
    /// What the next `target` finds selected (tests: Jake selected text first).
    private var pendingSelection: TextSpan?

    /// `context`: what the Test set entry says Jake was dictating into (#15 manifest `context`).
    public init(context: AppContext = .unknown) { self.current = context }

    public func context() -> AppContext { current }

    public func appChanges() -> AsyncStream<AppContext> {
        let (stream, continuation) = AsyncStream<AppContext>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in Task { await self?.stopWatching(id) } }
        focusWatchers[id] = continuation
        continuation.yield(current)
        return stream
    }

    /// Tests: Jake switches to `app` mid-Dictation.
    public func moveFocus(to app: AppContext) {
        current = app
        for watcher in focusWatchers.values { watcher.yield(app) }
    }

    private func stopWatching(_ id: UUID) { focusWatchers[id] = nil }

    /// Tests: Jake selects `span` of the field before the next fn-down.
    public func select(_ span: TextSpan) { pendingSelection = span }

    public func target() -> Target? {
        let selection = pendingSelection
        pendingSelection = nil
        return Target(serial: delivered.count, focus: FocusSnapshot(pid: 0, fieldFingerprint: "headless"), selection: selection)
    }

    // `async` like the requirement: a sync method beside the protocol's async
    // default would lose to it in a caller's `await`.
    public func read(at target: Target) async -> FieldText? {
        FieldText.reading(fieldText, offset: 0, selection: target.selection, bundleID: current.bundleID,
                          fieldFingerprint: "headless")
    }

    /// Like `TargetApp.replace` with no app to ask: only while the span still reads `expected`.
    public func replace(_ span: TextSpan, expected: String, with text: String, at target: Target) async -> ReplaceOutcome {
        guard Self.text(in: fieldText, at: span) == expected else { return .refused(.textChanged) }
        let utf16 = fieldText.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: span.location)
        let before = String(String(utf16[..<start])?.suffix(40) ?? "")
        fieldText.replaceSubrange(start..<utf16.index(start, offsetBy: span.length), with: text)
        return .replaced(InsertionReceipt(appBundleID: current.bundleID, fieldFingerprint: "headless",
                                          caretAfter: span.location + text.utf16.count, contextBefore: before,
                                          contextAfter: "", insertedAt: Date()))
    }

    /// The text at `span` of `text`, in UTF-16 offsets; nil when the span runs past it.
    static func text(in text: String, at span: TextSpan) -> String? {
        let utf16 = text.utf16
        guard span.location >= 0, span.length >= 0, span.location + span.length <= utf16.count else { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: span.location)
        let end = utf16.index(start, offsetBy: span.length)
        return String(utf16[start..<end])
    }

    /// Same guard as every insert (focus never moves, nobody types here, and the
    /// field is always known, so no time counts: it inserts).
    public func insert(_ text: String, for id: DictationID, at target: Target) -> Delivery {
        switch InsertGuard.decide(target: target.focus, focusNow: target.focus, inputSinceMark: false, sinceCapture: .zero) {
        case .hold(let reason):
            return .notInserted(reason)
        case .insert:
            delivered[id] = text
            typedOrder.append(id)
            let before = String(fieldText.suffix(40))
            fieldText += text
            return .inserted(InsertionReceipt(appBundleID: current.bundleID, fieldFingerprint: "headless",
                                              caretAfter: fieldText.utf16.count, contextBefore: before, contextAfter: "",
                                              insertedAt: Date()))
        }
    }
}

/// The same modules as `LexiconSystem` minus the keyboard, AppText, Fixes and
/// the inbox. History and the Lexicon live under a temporary `AppPaths` unless
/// a caller passes real ones (read-only use only: never point eval at Jake's History).
public final class HeadlessSystem: Sendable {
    public let conductor: Conductor<HeadlessDestination>
    /// The Conductor's destination: what was typed, and the one field it was typed into.
    public let destination: HeadlessDestination
    public let history: HistoryStore
    /// The Conductor's Lexicon, so a caller can import words before a run (`lexicon-eval --lexicon`).
    public let lexicon: Lexicon

    /// `cloud`: real providers, used only when `preferences` name a cloud model
    /// and the environment holds its key; tests pass a scripted link.
    /// `clock` times the race deadline and the local model's idle unload; tests pass a fake one.
    public static func make(paths: AppPaths, context: AppContext, preferences: Preferences,
                            local: (any LocalTranscriber)?, cloud: CloudLink = .network,
                            clock: any Clock<Duration> = ContinuousClock()) throws -> HeadlessSystem {
        let history = try HistoryStore(paths: paths)
        let lexicon = try Lexicon(paths: paths)
        let destination = HeadlessDestination(context: context)
        let conductor = Conductor(
            recorder: Recorder(), speech: SpeechEngine(local: local, cloud: cloud, clock: clock), cleanup: Cleanup(),
            lexicon: lexicon, history: history, destination: destination,
            preferences: PreferencesStore(fixed: preferences), secrets: Secrets(.environment),
            keyboard: nil, fixes: nil, jev: nil)
        return HeadlessSystem(conductor: conductor, destination: destination, history: history, lexicon: lexicon)
    }

    init(conductor: Conductor<HeadlessDestination>, destination: HeadlessDestination, history: HistoryStore,
         lexicon: Lexicon) {
        self.conductor = conductor
        self.destination = destination
        self.history = history
        self.lexicon = lexicon
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
    public nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { clip in await self.transcribe(clip, terms: terms, priority: priority) }
    }

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) -> String {
        heard.append(clip)
        return text
    }
}
