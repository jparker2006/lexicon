import LexiconDomain
import AudioCapture
import Transcription
import Cleanup
import History

// After fn-up (or Esc) when the mic ran but gave no sound: the row and the notice.

extension Conductor {
    /// Every frame was exactly zero (a dead or contended device), or not one frame came
    /// (an engine that ran and never delivered). A quiet room is never exact zeros, so
    /// this is the mic, not Jake. Nothing is transcribed at fn-up (a streaming provider has
    /// already had the zeros, which hold nothing of Jake's): there are no words in zeros, and
    /// a model asked anyway may make some up. The row keeps the audio it got.
    func noSound(_ id: DictationID, _ sound: InputSound, attempt: consuming SpeechAttempt,
                 cleaning: CleanupSession) async -> DictationResult {
        attempt.cancel()
        await cleaning.cancel()
        history.record(.failed(id, reason: "microphone: \(sound)"))
        log.notice("Dictation \(id, privacy: .public) failed: no sound from the microphone (\(String(describing: sound), privacy: .public))")
        // The notice alone, as when the mic does not start: `finished(.failed)` would put
        // "No speech heard" over it, with a second error sound.
        emit(.notice(.microphoneSilent))
        return DictationResult(id: id, status: .failed, versions: nil, cleanup: nil, model: nil, lag: nil,
                               attempts: [])
    }
}
