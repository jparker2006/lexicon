import Foundation
import LexiconDomain
import AudioCapture
import Transcription
import Cleanup
import WordStore
import History

// What happens to a Dictation that got no text the first time: one the last run
// left unfinished (launch recovery), and one no engine could hear (waiting).
// Neither is typed when its text finally comes: text that arrives late waits
// for paste-last (#4), so both land with no target.

extension Conductor {
    /// Cleanup's deadline when nobody waits at the cursor (recovery, a waiting Dictation's later try).
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
        guard let clip = await Self.read(item.audio) else {
            history.record(.failed(id, reason: "audio unreadable"))
            emit(.finished(id, .failed))
            return DictationResult(id: id, status: .failed, versions: nil, cleanup: nil, model: nil, lag: nil,
                                   attempts: [])
        }
        let preferences = preferences.snapshot()
        // Local only. Whether this Dictation began in Private mode, or in an
        // always-private app, was decided at its fn-down and not kept (#5).
        let words = await lexicon.forDictation(in: item.app)
        let speechPlan = SpeechPlan.make(preferences: preferences, access: nil, terms: words.terms)
        let cleanupPlan = CleanupPlan.make(preferences: preferences, access: nil, terms: words.terms,
                                           rules: words.rules, app: item.app)
        let run = DictationRun(id: id, origin: .recovered, purpose: item.purpose, context: item.app, clip: clip,
                               cleaning: cleanup.begin(plan: cleanupPlan),
                               cleanupDeadline: Self.backgroundCleanupDeadline, access: nil, target: nil,
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
        let audio = history.audioURL(for: run.id)
        waiting[run.id] = Task {
            var run = run
            // Waiting can last days: a clip the disk holds in full is read back per try, not kept in RAM.
            if let clip = run.clip, await Self.read(audio)?.samples.count == clip.samples.count { run.clip = nil }
            await self.retry(waiting: run, audio: audio, after: reason)
        }
    }

    private func retry(waiting run: DictationRun, audio: URL, after reason: SpeechUnavailable) async {
        defer { waiting[run.id] = nil }
        var reason = reason
        while true {
            await speech.untilRetry(after: reason)
            if Task.isCancelled { return }  // a cancelled sleep returns at once: never spin
            guard await stillWaiting(run.id) else { return }
            var clip = run.clip
            if clip == nil { clip = await Self.read(audio) }
            guard let clip else { continue }
            // Today's settings: a model installed or chosen since then is the one that answers,
            // and the cloud only if both fn-down and now allow it (Private mode turned on meanwhile).
            let preferences = preferences.snapshot()
            let access = run.access == nil ? nil
                : CloudAccess.granted(by: preferences, app: run.context, keys: secrets.lookup)
            let words = await lexicon.forDictation(in: run.context)
            let plan = SpeechPlan.make(preferences: preferences, access: access, terms: words.terms)
            // Background: a retry never goes ahead of the Dictation Jake is making now.
            let outcome = await speech.transcribe(clip, plan: plan, priority: .background)
            if case .unavailable(let still) = outcome, still.waits {
                if still != reason { history.record(.waiting(run.id, reason: String(describing: still))) }
                reason = still
                continue
            }
            // Deleted while it was being heard: nothing left to save it to.
            guard await stillWaiting(run.id) else { return }
            let cleanupPlan = CleanupPlan.make(preferences: preferences, access: access, terms: words.terms,
                                               rules: words.rules, app: run.context)
            let late = DictationRun(id: run.id, origin: run.origin, purpose: run.purpose, context: run.context,
                                    clip: nil, cleaning: cleanup.begin(plan: cleanupPlan),
                                    cleanupDeadline: Self.backgroundCleanupDeadline, access: access, target: nil,
                                    releasedAt: nil, previous: .waiting, hold: nil)
            _ = await land(outcome, late)
            return
        }
    }

    /// Still owed text. A `.waiting` write SQLite dropped leaves the row unfinished,
    /// which counts; a deleted row, or one given text another way (a manual Retry), does not.
    private func stillWaiting(_ id: DictationID) async -> Bool {
        guard let status = await history.dictation(id)?.status else { return false }
        return [.recording, .transcribing, .waiting].contains(status)
    }

    /// Off the Conductor's actor: a long Dictation's file takes a while, and fn-down must not wait on it.
    private static func read(_ url: URL) async -> AudioClip? {
        await Task.detached { try? CAFFile.read(url) }.value
    }
}
