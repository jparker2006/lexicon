import Foundation
import LexiconDomain
import AudioCapture
import Transcription
import Cleanup
import WordStore
import History

// What happens to a Dictation that got no text the first time: one the last run
// left unfinished (launch recovery), and one no engine could hear (waiting).
// Neither is ever typed by recovery: a recovered run has no target.

extension Conductor {
    /// Cleanup's deadline when nobody waits at the cursor (recovery).
    static var backgroundCleanupDeadline: Duration { .seconds(10) }

    /// Launch: transcribe what the last run left unfinished. Never typed.
    /// Safe to call twice (History.recover is idempotent; ids already in flight are skipped).
    public func recover() async {
        for item in await history.recover() where inFlight[item.id] == nil && waiting[item.id] == nil {
            inFlight[item.id] = Task { await self.recover(item) }
        }
    }

    private func recover(_ item: UnfinishedDictation) async -> DictationResult {
        defer { inFlight[item.id] = nil }
        let id = item.id
        guard let clip = try? CAFFile.read(item.audio) else {
            history.record(.failed(id, reason: "audio unreadable"))
            emit(.finished(id, .failed))
            return DictationResult(id: id, status: .failed, versions: nil, cleanup: nil, model: nil, lag: nil,
                                   attempts: [])
        }
        let preferences = preferences.snapshot()
        // An app recovery can't name may have been an always-private one (#5): nothing leaves the Mac.
        let access = item.app.bundleID == nil ? nil
            : CloudAccess.granted(by: preferences, app: item.app, keys: secrets.lookup)
        let words = await lexicon.forDictation(in: item.app)
        let speechPlan = SpeechPlan.make(preferences: preferences, access: access, terms: words.terms)
        let cleanupPlan = CleanupPlan.make(preferences: preferences, access: access, terms: words.terms,
                                           rules: words.rules, app: item.app)
        let run = DictationRun(id: id, origin: .recovered, purpose: item.purpose, context: item.app, clip: clip,
                               speechPlan: speechPlan, cleanupPlan: cleanupPlan,
                               cleaning: cleanup.begin(plan: cleanupPlan),
                               cleanupDeadline: Self.backgroundCleanupDeadline, access: access, target: nil,
                               releasedAt: nil, previous: item.wasWaiting ? .waiting : nil, hold: nil)
        emit(.transcribing(id))
        let result = await land(await speech.transcribe(clip, plan: speechPlan, priority: .background), run)
        if result.status == .recovered { emit(.notice(.recovered(id))) }
        return result
    }

    /// The waiting branch's other half: try again until there is text. Jake is
    /// never asked to redo it (#4). Started once per Dictation by `land`.
    func retryWhenReady(_ run: DictationRun, after reason: SpeechUnavailable) {
        guard waiting[run.id] == nil else { return }
        waiting[run.id] = Task { await self.retry(waiting: run, after: reason) }
    }

    private func retry(waiting run: DictationRun, after reason: SpeechUnavailable) async {
        defer { waiting[run.id] = nil }
        var reason = reason
        while true {
            await speech.untilRetry(after: reason)
            if Task.isCancelled { return }  // a cancelled sleep returns at once: never spin
            // Deleted, or given text another way (a manual Retry): nothing is waiting any more.
            guard await history.dictation(run.id)?.status == .waiting else { return }
            // Background: a retry never goes ahead of the Dictation Jake is making now.
            let outcome = await speech.transcribe(run.clip, plan: run.speechPlan, priority: .background)
            if case .unavailable(let still) = outcome, still.waits {
                if still != reason { history.record(.waiting(run.id, reason: String(describing: still))) }
                reason = still
                continue
            }
            var next = run
            next.previous = .waiting
            next.cleaning = cleanup.begin(plan: run.cleanupPlan)
            // A live Dictation keeps its target, so its late text still passes InsertGuard
            // before it is typed; a recovered one has none and lands as recovered.
            _ = await land(outcome, next)
            return
        }
    }
}
