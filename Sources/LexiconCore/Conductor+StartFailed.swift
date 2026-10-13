import os
import LexiconDomain
import AudioCapture
import KeyInput
import History

// fn-down when the mic does not start: the row and the notice, never a lost Dictation.

extension Conductor {
    /// Capture didn't start: no mic permission, no device, Core Audio stuck past
    /// the start limit (#142), or a file that can't be read. Nothing was captured,
    /// so nothing can be lost; a live row says what happened, unless the press was a stray tap.
    func startFailed(_ start: RunStart, _ error: RecorderError, ends: AsyncStream<RunEnd>) async -> DictationResult {
        let id = start.id
        let discarded: Bool
        if start.origin != .live {
            // A file that can't be read was never a Dictation: no row, and eval reports "nothing".
            discarded = true
        } else if id == capturingID {
            // Give up the capture slot, or every later fn-down finds it taken and is dropped.
            // A stop, not a discard: with fn still down the pill plays the stop sound and leaves
            // "recording", or it would never show the notice (a press it never confirmed, it
            // ignores). The press's own release, still to come, names this id and so ends nothing.
            endCapture(id, .stop(at: .now()))
            keyboard?.dictationEnded(id)  // the recognizer still thinks it records, and would keep Esc
            discarded = false
        } else {
            // Released before the mic answered: its end is already in `ends`.
            discarded = await ends.first { _ in true }.map { !$0.isStop } ?? false
        }
        if discarded {
            history.record(.discarded(id))
        } else {
            history.record(.failed(id, reason: "microphone: \(error)"))
        }
        if start.origin == .live {  // a file's error names its path, which may be the Test set's
            log.error("Dictation \(id, privacy: .public) has no mic: \(String(describing: error), privacy: .public)")
        }
        emit(.notice(.microphoneUnavailable(String(describing: error))))
        return discarded ? .nothing(id) : DictationResult(id: id, status: .failed, versions: nil, cleanup: nil,
                                                          model: nil, lag: nil, attempts: [])
    }
}
