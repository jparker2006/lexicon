import Foundation
public import LexiconDomain
import Inbox
import KeyInput
public import AudioCapture
public import Transcription
import WordStore
public import History
public import AppText
import Jev
public import Fixes

/// The live app, wired. The composition root: the only place concrete modules
/// meet. The app shell creates one of these and the UI; nothing else constructs
/// a Recorder, a HistoryStore or a TargetApp.
public typealias LiveConductor = Conductor<TargetApp>

public final class LexiconSystem: Sendable {
    public let paths: AppPaths
    public let conductor: LiveConductor
    public let history: HistoryStore
    public let preferences: PreferencesStore
    public let secrets: Secrets
    public let recorder: Recorder
    let keyboard: Keyboard
    let lexicon: Lexicon
    let fixes: FixEngine
    let inbox: InboxWatcher
    let testHooks: Bool

    /// Throws `KeyboardError.notTrusted` when Accessibility is missing; the
    /// shell shows onboarding and retries after relaunch (#6).
    public static func live(paths: AppPaths, bundleID: String, local: (any LocalTranscriber)?,
                            prompter: any FixPrompter, testHooks: Bool) throws -> LexiconSystem {
        fatalError("not implemented")
    }

    init() { fatalError("not implemented") }

    /// Starts everything that runs for the life of the app:
    /// 1. `conductor.recover()` (after the tap is live, so fn works immediately)
    /// 2. key commands -> `conductor.handle`
    /// 3. inbox messages -> the router below
    /// 4. `recorder.prepare(.microphone(...))`
    /// 5. `preferences.changes()` -> `speech.preferencesChanged` (local model residency)
    public func run() async {
        fatalError("not implemented")
    }

    /// The ONE list of inbox routes (exhaustive switch over InboxMessage).
    func route(_ message: InboxMessage) async {
        switch message {
        case .promptSubmitted(let prompt):
            if let directory = prompt.workingDirectory { await lexicon.noteProject(URL(filePath: directory)) }
            await fixes.promptSubmitted(prompt)
        case .dictateFile(let path):
            guard testHooks else { return }
            _ = await conductor.dictate(file: URL(filePath: path), pace: .realtime)
        }
    }
}
