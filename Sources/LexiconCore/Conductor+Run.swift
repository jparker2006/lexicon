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

// One Dictation, top to bottom. This file is the trace: every step is one call
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

        // fn-down. Capture starts first; nothing network-bound runs in front of it.
        async let contextValue = destination.context()
        let capture: LiveCapture
        do {
            capture = try await recorder.start(start.input, writingTo: history.audioURL(for: id), since: start.began)
        } catch {
            // Give up the capture slot, or every later fn-down finds it taken and is dropped. A discard,
            // not a cancel: a cancel sends `stopped`, and the pill would play a stop sound for a mic that never started.
            // The press's own release, still to come, names this id and so ends nothing.
            endCapture(id, .discard)
            emit(.notice(.microphoneUnavailable(String(describing: error))))
            return .nothing(id)  // nothing was captured, so nothing can be lost
        }
        let context = await contextValue
        // Granted once the app is known: an always-private app gets no access (#5).
        // TODO: while this Dictation runs, Private mode turned on -> access?.revoke(.privateModeOn);
        // focus moving into an always-private app -> access?.revoke(.alwaysPrivateApp).
        let access = CloudAccess.granted(by: start.preferences, app: context, keys: secrets.lookup)
        history.record(.began(id, origin: start.origin, purpose: start.purpose, at: Date(), app: context))
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
        jev?.prewarm(access)
        await fixes?.dictationStarted()
        let signals = capture.signals
        Task { if await signals.firstAudio() != nil { self.emit(.listening(id)) } }

        // Wait for fn-up (or Esc, a stray tap, end of file). The 20-minute cap and the
        // 19-minute warning chime live in FnGesture, which emits a normal stop (#18).
        switch await nextEnd(ends, signals: signals) {
        case .discard:
            _ = await capture.stop(.immediately)
            attempt.cancel()
            await cleaning.cancel()
            history.record(.discarded(id))
            return .nothing(id)

        case .cancel:
            // Esc (#18): stop now, still transcribe and save, never type (no target).
            // It lands as notInserted with text, and paste-last gets it back.
            let take = await capture.stop(.immediately)
            history.record(.audioEnded(id, take.summary))
            noteStorage(take.summary)
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

    /// Text (or no text) -> cleanup -> History -> the cursor. Shared by live,
    /// waiting, retry and recovery, so they cannot drift apart.
    /// `run.target == nil` means never type: recovery and retry have no target.
    func land(_ outcome: SpeechOutcome, _ run: DictationRun) async -> DictationResult {
        let id = run.id
        switch outcome {
        case .unavailable(let reason) where reason.waits:
            // Keep the audio and show "waiting"; Jake is never asked to redo it. A
            // waiting Dictation gives up its turn, so later Dictations still insert.
            history.record(.waiting(id, reason: String(describing: reason)))
            log.notice("Dictation \(id, privacy: .public) waiting: \(String(describing: reason), privacy: .private)")
            if reason.waitsForNetwork { emit(.notice(.waitingForNetwork(id))) }
            releaseInsertTurn(id)
            run.hold?.end()
            await run.cleaning.cancel()  // the retry cleans with a fresh session
            retryWhenReady(run, after: reason)
            emit(.finished(id, .waiting))
            return DictationResult(id: id, status: .waiting, versions: nil, cleanup: nil, model: nil, lag: nil,
                                   attempts: [])

        case .unavailable(let reason):
            history.record(.failed(id, reason: String(describing: reason)))
            log.notice("Dictation \(id, privacy: .public) failed: \(String(describing: reason), privacy: .private)")
            emit(.finished(id, .failed))
            return DictationResult(id: id, status: .failed, versions: nil, cleanup: nil, model: nil, lag: nil,
                                   attempts: [])

        case .text(let heard):
            for record in heard.attempts { history.record(.attempted(id, record)) }
            let cleaned = await run.cleaning.finish(modelText: heard.text, deadline: run.cleanupDeadline)
            // Queued for disk BEFORE it is typed. Fire-and-forget FIFO: still no wait on SQLite.
            let typing = run.purpose == .type && run.target != nil
            history.record(.textReady(id, cleaned.versions, cleanup: cleaned.outcome, model: heard.model,
                                      typing: typing))

            var delivery = Delivery.historyOnly
            var lag: Duration?
            if typing, let target = run.target {
                await insertTurn(id)  // Dictations insert in the order they were spoken (#18)
                delivery = await destination.insert(cleaned.versions.cleaned, for: id, at: target)  // text at the cursor
                lag = run.releasedAt.map { HostTime.now().duration(since: $0) }
            }
            releaseInsertTurn(id)  // the next Dictation types now, not after the bookkeeping below
            run.hold?.end()  // the Dictation landed: App Nap may return

            // Everything below is after the text landed: off the fn-up path.
            switch delivery {
            case .inserted(let receipt):
                history.record(.delivered(id, receipt, lag: lag))
                await fixes?.didInsert(id, text: cleaned.versions.cleaned, app: run.context, receipt: receipt,
                                       access: run.access)
            case .notInserted(let reason):
                history.record(.notInserted(id, reason))
                emit(.notice(.readyToPaste(id)))
            case .historyOnly:
                // Esc'd live Dictation: say it's waiting in paste-last (#18 indicator state).
                if run.origin == .live, run.purpose == .type { emit(.notice(.readyToPaste(id))) }
            }
            // Only a live target may change another app: recovered or late text is never typed (#4).
            if case .respeak(let fixing) = run.purpose, run.target != nil {
                _ = await fixes?.respeak(cleaned.versions.cleaned, fixing: fixing, access: run.access)
            }
            let status = DictationStatus.landed(delivery, origin: run.origin, previous: run.previous)
            // `lag` is the spec's number: fn-up to the target app reading the paste (scripts/lag-report.sh).
            let lagText = lag.map { "lag \($0.milliseconds) ms, " } ?? ""
            log.notice("""
                Dictation \(id, privacy: .public) \(status.rawValue, privacy: .public): \(lagText, privacy: .public)\
                engine \(heard.model.id, privacy: .public), speech \(heard.finalizeToText.milliseconds, privacy: .public) ms
                """)
            emit(.finished(id, status))
            return DictationResult(id: id, status: status, versions: cleaned.versions, cleanup: cleaned.outcome,
                                   model: heard.model, lag: lag, attempts: heard.attempts)
        }
    }

    /// The disk was nearly full or a write failed: the Dictation finishes from
    /// RAM as normal, and Jake is told its audio was not saved (#4).
    func noteStorage(_ summary: AudioSummary) {
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

extension Duration {
    /// Whole milliseconds, for the log.
    var milliseconds: Int64 { Int64((self / .milliseconds(1)).rounded()) }
}
