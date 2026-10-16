import Foundation
public import LexiconDomain
public import KeyInput
public import AudioCapture
public import Transcription
import Cleanup
public import WordStore
public import History
public import AppText

/// The live app, wired. The composition root: the only place concrete modules
/// meet. The app shell creates one of these and the UI; nothing else constructs
/// a Recorder, a HistoryStore or a TargetApp.
public typealias LiveConductor = Conductor<TargetApp>

public final class LexiconSystem: Sendable {
    public let paths: AppPaths
    public let conductor: LiveConductor
    public let history: HistoryStore
    public let preferences: PreferencesStore
    public let recorder: Recorder
    /// The one Lexicon: every Dictation reads it at fn-down, and the Lexicon page edits it.
    public let lexicon: Lexicon
    /// Where Dictations are typed. The test hooks paste through the same one.
    public let text: TargetApp
    /// Why fn is off (no Accessibility, or no listen access); nil while it works.
    public let fnOff: KeyboardError?
    /// The fn tap; nil while fn is off. The test hooks press keys through it.
    public let keyboard: Keyboard?
    /// Settings and the Conductor share this exact credential owner.
    private let secrets: Secrets
    public let credentials: CredentialCommand
    let speech: SpeechEngine

    /// Starts the fn tap first: fn must work within 150 ms of process start, and
    /// a press before the key loop runs waits in `Keyboard.commands`, in order.
    /// Without Accessibility the rest still opens, so History and the menu work.
    /// Throws only when History or the Lexicon can't open their databases.
    ///
    /// Not wired before their tickets: Fixes and Jev (M4, M5: Jev never runs
    /// during plain dictation), the inbox (no hooks before the after-M1 grill)
    /// and code Terms (no model takes Terms before M2).
    public static func live(paths: AppPaths, bundleID: String, local: (any LocalTranscriber)?,
                            keys: KeyboardConfig) throws -> LexiconSystem {
        // One clock for the tap and AppText, or the late-text rule never sees typing.
        let input = InputClock()
        let keyboard: Keyboard?
        let fnOff: KeyboardError?
        do {
            keyboard = try Keyboard.start(keys, input: input)
            fnOff = nil
        } catch {
            keyboard = nil
            fnOff = error
        }
        // After the tap: a press while these open waits in `Keyboard.commands`, in order,
        // and is a Dictation once the key loop runs. If they throw, the idle tap costs nothing.
        let history = try HistoryStore(paths: paths)
        let lexicon = try Lexicon(paths: paths)
        let preferences = PreferencesStore()
        let recorder = Recorder()
        let speech = SpeechEngine(local: local)
        let text = TargetApp(input: input)
        let secrets = Secrets(.keychain(service: bundleID))
        let conductor = Conductor(
            recorder: recorder, speech: speech, cleanup: Cleanup(), lexicon: lexicon,
            history: history, destination: text, preferences: preferences,
            secrets: secrets, keyboard: keyboard, fixes: nil, jev: nil)
        return LexiconSystem(paths: paths, conductor: conductor, history: history, preferences: preferences,
                             recorder: recorder, lexicon: lexicon, text: text, fnOff: fnOff, keyboard: keyboard,
                             secrets: secrets, speech: speech)
    }

    init(paths: AppPaths, conductor: LiveConductor, history: HistoryStore, preferences: PreferencesStore,
         recorder: Recorder, lexicon: Lexicon, text: TargetApp, fnOff: KeyboardError?, keyboard: Keyboard?,
         secrets: Secrets, speech: SpeechEngine) {
        self.paths = paths
        self.conductor = conductor
        self.history = history
        self.preferences = preferences
        self.recorder = recorder
        self.lexicon = lexicon
        self.text = text
        self.fnOff = fnOff
        self.keyboard = keyboard
        self.secrets = secrets
        self.credentials = secrets.credentials
        self.speech = speech
    }

    #if DEBUG
    /// The app's closed test-hook bridge to its Dev-owned credential fixture.
    public func settingsFixture(
        _ action: SettingsFixtureAction,
        completion: @escaping @Sendable (SettingsFixtureObservation) -> Void
    ) {
        secrets.settingsFixture(action, completion: completion)
    }
    #endif

    /// Everything that runs for the life of the app, all at once:
    /// 1. key commands -> `conductor.follow`, first, so fn works while the rest starts
    /// 2. crash recovery (never typed), then the audio retention sweep
    /// 3. `recorder.prepare`, so the first fn-down only starts the hardware
    /// 4. the local model loads in the background (the first load of a new build
    ///    compiles for about 25 s), then follows the settings (Private mode, idle unload)
    public func run() async {
        let launched = preferences.snapshot()
        // Subscribed before anything starts, so a change made meanwhile is not missed.
        let changes = preferences.changes()
        await withDiscardingTaskGroup { group in
            if let keyboard { group.addTask { await self.conductor.follow(keyboard.commands) } }
            group.addTask {
                await self.conductor.recover()
                await self.history.sweepAudio(now: Date())
            }
            group.addTask { self.recorder.prepare(.microphone(deviceUID: launched.microphoneUID)) }
            group.addTask { await self.speech.warmUp(launched) }
            group.addTask { for await changed in changes { await self.speech.preferencesChanged(changed) } }
        }
    }

    /// After first-run setup installs the model: load it now, as at launch, so
    /// the setup window's first fn press doesn't wait on the load.
    public func loadModel() async {
        await speech.warmUp(preferences.snapshot())
    }
}
