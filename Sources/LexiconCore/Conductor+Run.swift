import Foundation
import os
import LexiconDomain
import KeyInput
import AudioCapture
import Transcription
import Cleanup
import WordStore
import History
import AppText
import Jev
import Fixes

// One Dictation, top to bottom. This file is the trace, from fn-down to fn-up,
// and `Conductor+Land.swift` carries it on to the cursor: every step is one call
// into the module that owns that knowledge. It is written as real code (not
// pseudocode) so the build proves the module APIs fit together.

extension Conductor {
    /// `hold` was taken at fn-down (`handle(.dictationBegan)`); it keeps App Nap
    /// off until the text lands and is released on every way out of this run.
    func run(_ start: RunStart, ends: AsyncStream<RunEnd>, hold: LatencyHold) async -> DictationResult {
        let id = start.id
        defer {
            inFlight[id] = nil
            releaseInsertTurn(id)  // every exit gives up its place in the insert order
            hold.end()  // idempotent: usually already ended in `land`
        }

        // fn-down. Capture starts first; nothing network-bound runs in front of it. The row
        // doesn't wait on the mic: a start that fails or never returns still leaves a trace.
        async let began = beginRow(start)
        let capture: LiveCapture
        do {
            capture = try await recorder.start(start.input, writingTo: history.audioURL(for: id), since: start.began)
        } catch {
            _ = await began  // the row exists before its outcome is recorded
            return await startFailed(start, error, ends: ends)
        }
        let context = await began
        // Granted once the app is known: an always-private app gets no access (#5).
        let access = CloudAccess.granted(by: start.preferences, for: .app(context), keys: secrets.lookup)
        // Private mode turned on, or focus moving into an always-private app, cuts the stream at once;
        // local finishes (#5).
        let privacyWatch = access.map { revokeWhenDenied($0, in: context, followingFocus: true) }
        defer { privacyWatch?.cancel() }
        emit(.started(id))

        // Words for this Dictation (sub-ms, in memory), then open the stream.
        // The socket's cold TLS (95-635 ms) overlaps Jake talking.
        let words = await lexicon.forDictation(in: context)
        let speechPlan = SpeechPlan.make(preferences: start.preferences, access: access, terms: words.terms)
        let attempt = await speech.begin(feed: capture.feed, plan: speechPlan)

        // Cleanup reads the provider's finalized segments while Jake talks: finished
        // sentences are cleaned before fn-up, so after it only the tail waits.
        let cleanupPlan = CleanupPlan.make(preferences: start.preferences, access: access, terms: words.terms,
                                           rules: words.rules, app: context)
        let cleaning = cleanup.begin(plan: cleanupPlan, segments: attempt.segments)
        // Jev only answers fixes: plain dictation never opens a connection to it.
        if case .respeak = start.purpose { jev?.prewarm(access) }
        await fixes?.dictationStarted()
        let signals = capture.signals
        Task { if await signals.firstAudio() != nil { self.emit(.listening(id)) } }

        // Wait for fn-up (or the hands-free stop press, Esc, a stray tap, sleep, the cap,
        // end of file). The cap is a normal stop from FnGesture.
        switch await nextEnd(ends, signals: signals) {
        case .discard:
            _ = await capture.stop(.immediately)
            attempt.cancel()
            await cleaning.cancel()
            history.record(.discarded(id))
            return .nothing(id)

        case .cancel:
            // Esc (#18): stop now, still transcribe and save, never type (no target).
            // It lands as notInserted with text, and paste-last gets it back. A dead mic has no words to save.
            let take = await capture.stop(.immediately)
            history.record(.audioEnded(id, take.summary))
            noteStorage(take.summary)
            guard take.sound == .real else {                           // a dead mic: nothing to transcribe
                return await noSound(id, take.sound, attempt: attempt, cleaning: cleaning)
            }
            emit(.transcribing(id))
            let outcome = await attempt.finish(take.clip)
            let run = DictationRun(id: id, origin: start.origin, purpose: start.purpose, context: context,
                                   clip: take.clip, cleaning: cleaning,
                                   cleanupDeadline: start.preferences.cleanupDeadline,
                                   access: access, target: nil, releasedAt: nil, previous: nil, hold: hold)
            return await land(outcome, run)

        case .stop(let releasedAt):
            // fn-up. Where the text goes is captured now, in parallel with the tail.
            async let target = destination.target()
            let take = await capture.stop(.released(at: releasedAt))  // adaptive tail, cap 200 ms
            history.record(.audioEnded(id, take.summary))              // enqueue only; never waits on SQLite
            noteStorage(take.summary)
            guard take.sound == .real else {                           // a dead mic: nothing to transcribe
                return await noSound(id, take.sound, attempt: attempt, cleaning: cleaning)
            }
            emit(.transcribing(id))
            let outcome = await attempt.finish(take.clip)              // finalize + race local + deadline
            let run = DictationRun(id: id, origin: start.origin, purpose: start.purpose, context: context,
                                   clip: take.clip, cleaning: cleaning,
                                   cleanupDeadline: start.preferences.cleanupDeadline,
                                   access: access, target: await target, releasedAt: releasedAt,
                                   previous: nil, hold: hold)
            return await land(outcome, run)
        }
    }

    /// The Dictation's History row, at fn-down. Off the actor, in parallel with
    /// the mic start. Returns the app it began in.
    nonisolated func beginRow(_ start: RunStart) async -> AppContext {
        let context = await destination.context()
        history.record(.began(start.id, origin: start.origin, purpose: start.purpose, at: Date(), app: context))
        return context
    }

    /// Audio lost on the way (DECISIONS item 84): the Dictation is heard and
    /// typed from the rest, and Jake is told. The disk was nearly full or a write
    /// failed: it finishes from RAM as normal, and Jake is told its audio was not
    /// saved (#4). That comes last, so when both happen the pill keeps the disk line.
    func noteStorage(_ summary: AudioSummary) {
        if summary.lost > .zero { emit(.notice(.audioLost)) }
        if summary.storage == .ramOnly { emit(.notice(.diskTrouble)) }
    }

    /// First of: a key/sleep end from `ends`, or end of input for a file source.
    /// A microphone's `inputEnded()` returns only once the capture stops, and
    /// cancelling it returns nil at once, so the losing side never holds this up.
    /// Before either, nil means the input broke off (a file read failed): stop now,
    /// since nothing else will end a file Dictation.
    func nextEnd(_ ends: AsyncStream<RunEnd>, signals: CaptureSignals) async -> RunEnd {
        await withTaskGroup(of: RunEnd.self) { group in
            // `ends` finishing with no element should not happen; stopping is the safe reading.
            group.addTask { await ends.first { _ in true } ?? .stop(at: .now()) }
            group.addTask { .stop(at: await signals.inputEnded() ?? .now()) }
            defer { group.cancelAll() }
            return await group.next() ?? .stop(at: .now())
        }
    }
}
