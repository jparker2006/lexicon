import Foundation
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
            hold.end()  // idempotent: usually already ended in `land`
        }

        // fn-down. Capture starts first; nothing network-bound runs in front of it.
        async let contextValue = destination.context()
        let capture: LiveCapture
        do {
            capture = try await recorder.start(start.input, writingTo: history.audioURL(for: id))
        } catch {
            emit(.notice(.microphoneUnavailable(String(describing: error))))
            keyboard?.endDictation()
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

        // Wait for fn-up (or Esc, a stray tap, end of file).
        switch await nextEnd(ends, signals: signals) {
        case .discard:
            _ = await capture.stop(.immediately)
            attempt.cancel()
            await cleaning.cancel()
            history.record(.discarded(id))
            return .nothing(id)

        case .cancel:
            let take = await capture.stop(.immediately)
            attempt.cancel()
            await cleaning.cancel()
            history.record(.audioEnded(id, take.summary))
            history.record(.cancelled(id))
            emit(.finished(id, .cancelled))
            return DictationResult(id: id, status: .cancelled, versions: nil, cleanup: nil, model: nil, lag: nil,
                                   attempts: [])

        case .stop(let releasedAt):
            // fn-up. Where the text goes is captured now, in parallel with the tail.
            async let target = destination.target()
            let take = await capture.stop(.released(at: releasedAt))  // adaptive tail, cap 200 ms
            history.record(.audioEnded(id, take.summary))              // enqueue only; never waits on SQLite
            emit(.transcribing(id))
            let outcome = await attempt.finish(take.clip)              // finalize + race local + deadline
            let run = DictationRun(id: id, origin: start.origin, purpose: start.purpose, context: context,
                                   clip: take.clip, speechPlan: speechPlan, cleanupPlan: cleanupPlan,
                                   cleaning: cleaning, cleanupDeadline: start.preferences.cleanupBudget,
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
        case .unavailable(.offline), .unavailable(.providerError):
            // M1: keep the audio, show "waiting", retry when the network returns. Late
            // text is still guarded by the target check (same field, no typing since).
            history.record(.waiting(id, reason: "offline"))
            emit(.notice(.waitingForNetwork(id)))
            run.hold.end()  // a wait for the network may last hours; App Nap may return
            await speech.networkReturned()
            let again = await speech.transcribe(run.clip, plan: run.speechPlan, priority: run.localPriority)
            var next = run
            next.cleaning = cleanup.begin(plan: run.cleanupPlan)  // the failed attempt's segments are gone
            next.releasedAt = nil
            next.previous = .waiting
            return await land(again, next)

        case .unavailable(let reason):
            history.record(.failed(id, reason: String(describing: reason)))
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
                delivery = await destination.insert(cleaned.versions.cleaned, for: id, at: target)  // text at the cursor
                lag = run.releasedAt.map { HostTime.now().duration(since: $0) }
            }
            run.hold.end()  // the Dictation landed: App Nap may return

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
                break
            }
            if case .respeak(let fixing) = run.purpose {
                _ = await fixes?.respeak(cleaned.versions.cleaned, fixing: fixing, access: run.access)
            }
            let status = DictationStatus.landed(delivery, origin: run.origin, previous: run.previous)
            emit(.finished(id, status))
            return DictationResult(id: id, status: status, versions: cleaned.versions, cleanup: cleaned.outcome,
                                   model: heard.model, lag: lag, attempts: heard.attempts)
        }
    }

    /// First of: a key/sleep end from `ends`, or end of input for a file source.
    func nextEnd(_ ends: AsyncStream<RunEnd>, signals: CaptureSignals) async -> RunEnd {
        // TODO: race `ends.first { _ in true }` against `signals.inputEnded()` in a task group;
        // file input -> .stop(at: end-of-file host time); mic input -> inputEnded() never returns.
        // If `ends` finishes with no element (should not happen), treat as .stop(at: .now()).
        fatalError("not implemented")
    }
}
