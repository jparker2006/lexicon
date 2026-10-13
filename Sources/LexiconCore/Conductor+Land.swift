import Foundation
import os
import LexiconDomain
import Transcription
import Cleanup
import History
import AppText

// After fn-up: text (or no text) through Cleanup into History, then to the
// cursor. Live, waiting, retry and recovery all land here, so they cannot drift apart.

extension Conductor {
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
            return failed(id, reason)

        case .text(let heard):
            let cleaned = await run.cleaning.finish(modelText: heard.text, deadline: run.cleanupDeadline)
            // A filler-only answer ("Um.") gets past the engine's silence check and Cleanup strips
            // it to nothing: that is silence too. Typed, the empty Cmd-V would replace Jake's selection.
            // A Retry of a settled row leaves it as it was, engine runs included, as Retry does when
            // the engine hears silence.
            let blank = !cleaned.versions.cleaned.contains(where: { !$0.isWhitespace })
            if blank, run.isRetry { return .nothing(id) }
            for record in heard.attempts { history.record(.attempted(id, record)) }
            if blank { return failed(id, .silence) }
            // Queued for disk BEFORE it is typed. Fire-and-forget FIFO: still no wait on SQLite.
            let typing = run.purpose == .type && run.target != nil
            // A Retry keeps the text it replaces as an earlier version (#213).
            history.record(run.isRetry
                ? .retried(id, cleaned.versions, cleanup: cleaned.outcome, model: heard.model, version: UUID())
                : .textReady(id, cleaned.versions, cleanup: cleaned.outcome, model: heard.model, typing: typing))

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
                // Esc'd or late live Dictation: say it's waiting in paste-last (#18 indicator state).
                // Not for a Retry of one already settled: Jake is looking at it in History.
                if run.origin == .live, run.purpose == .type, !run.isRetry {
                    emit(.notice(.readyToPaste(id)))
                }
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

    /// No text to land: the row keeps its audio.
    private func failed(_ id: DictationID, _ reason: SpeechUnavailable) -> DictationResult {
        history.record(.failed(id, reason: String(describing: reason)))
        log.notice("Dictation \(id, privacy: .public) failed: \(String(describing: reason), privacy: .private)")
        emit(.finished(id, .failed))
        return DictationResult(id: id, status: .failed, versions: nil, cleanup: nil, model: nil, lag: nil,
                               attempts: [])
    }
}

extension Duration {
    /// Whole milliseconds, for the log.
    var milliseconds: Int64 { Int64((self / .milliseconds(1)).rounded()) }
}
