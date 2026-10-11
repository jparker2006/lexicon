import Foundation
public import LexiconDomain
public import KeyInput
public import AudioCapture
public import Transcription
import Cleanup
import WordStore
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
    /// Where Dictations are typed. The test hooks paste through the same one.
    public let text: TargetApp
    /// Why fn is off (no Accessibility, or no listen access); nil while it works.
    public let fnOff: KeyboardError?
    let keyboard: Keyboard?
    let speech: SpeechEngine

    /// Starts the fn tap first: fn must work within 150 ms of process start, and
    /// a press before the key loop runs waits in `Keyboard.commands`, in order.
    /// Without Accessibility the rest still opens, so History and the menu work.
    /// Throws only when History or the Lexicon can't open their databases.
    ///
    /// Not wired before their tickets: Fixes and Jev (M4, M5: Jev never runs
    /// during plain dictation), the inbox (no hooks before the after-M1 grill)
    /// and code Terms (no model takes Terms before M2).
    public static func live(paths: AppPaths, bundleID: String, local: (any LocalTranscriber)?) throws -> LexiconSystem {
        // One clock for the tap and AppText, or the late-text rule never sees typing.
        let input = InputClock()
        let keyboard: Keyboard?
        let fnOff: KeyboardError?
        do {
            keyboard = try Keyboard.start(KeyboardConfig(), input: input)
            fnOff = nil
        } catch {
            keyboard = nil
            fnOff = error
        }
        let history = try HistoryStore(paths: paths)
        let preferences = PreferencesStore()
        let recorder = Recorder()
        let speech = SpeechEngine(local: local)
        let text = TargetApp(input: input)
        let conductor = Conductor(
            recorder: recorder, speech: speech, cleanup: Cleanup(), lexicon: try Lexicon(paths: paths),
            history: history, destination: text, preferences: preferences,
            secrets: Secrets(.keychain(service: bundleID)), keyboard: keyboard, fixes: nil, jev: nil)
        return LexiconSystem(paths: paths, conductor: conductor, history: history, preferences: preferences,
                             recorder: recorder, text: text, fnOff: fnOff, keyboard: keyboard, speech: speech)
    }

    init(paths: AppPaths, conductor: LiveConductor, history: HistoryStore, preferences: PreferencesStore,
         recorder: Recorder, text: TargetApp, fnOff: KeyboardError?, keyboard: Keyboard?, speech: SpeechEngine) {
        self.paths = paths
        self.conductor = conductor
        self.history = history
        self.preferences = preferences
        self.recorder = recorder
        self.text = text
        self.fnOff = fnOff
        self.keyboard = keyboard
        self.speech = speech
    }

    /// Everything that runs for the life of the app, all at once:
    /// 1. key commands -> `conductor.follow`, first, so fn works while the rest starts
    /// 2. crash recovery (never typed), then the audio retention sweep
    /// 3. `recorder.prepare`, so the first fn-down only starts the hardware
    /// 4. the local model loads in the background (the first load of a new build
    ///    compiles for about 25 s), then follows the settings (Private mode, idle unload)
    public func run() async {
        let launched = preferences.snapshot()
        // Subscribed before the warm-up, so a change made meanwhile is not missed.
        let changes = preferences.changes()
        await withDiscardingTaskGroup { group in
            if let keyboard { group.addTask { await self.conductor.follow(keyboard.commands) } }
            group.addTask {
                await self.conductor.recover()
                await self.history.sweepAudio(now: Date())
            }
            group.addTask { self.recorder.prepare(.microphone(deviceUID: launched.microphoneUID)) }
            group.addTask {
                await self.speech.warmUp(launched)
                for await changed in changes { await self.speech.preferencesChanged(changed) }
            }
        }
    }
}
