import Foundation
public import LexiconDomain
import Transcription
import Cleanup
import WordStore
import History

// History's ⋯ > Retry: the Dictation's saved audio heard again, its text
// replaced in History. Never typed: Jake is in the History window, and no
// target is captured, so `land` cannot insert it.

extension Conductor {
    /// `model` nil = the normal plan; otherwise the picker's choice. Does nothing
    /// (versions nil) while the Dictation is in flight, already being retried
    /// (here, or by the waiting loop, which keeps trying until it has text), once
    /// its audio is gone, or when the retry hears nothing: the row keeps what it had. A failed Dictation that gets text becomes not inserted
    /// (recovered, if it came from a crash).
    public func retry(_ id: DictationID, with model: SpeechModel?) async -> DictationResult {
        guard inFlight[id] == nil, waiting[id] == nil else { return .nothing(id) }
        // In `inFlight` like any Dictation being heard, so Quit waits for it to land.
        let task = Task { await self.retrying(id, with: model) }
        inFlight[id] = task
        return await task.value
    }

    private func retrying(_ id: DictationID, with model: SpeechModel?) async -> DictationResult {
        defer { inFlight[id] = nil }
        guard let record = await history.dictation(id), !record.status.isInFlight,
              let clip = await history.clip(id) else { return .nothing(id) }
        let preferences = preferences.snapshot()
        // Today's settings and today's access for the app it was dictated into.
        let access = CloudAccess.granted(by: preferences, app: record.app, keys: secrets.lookup)
        let words = await lexicon.forDictation(in: record.app)
        let speechPlan = SpeechPlan.make(preferences: preferences, access: access, terms: words.terms, forcing: model)
        // Background: a retry never goes ahead of the Dictation Jake is making now.
        let outcome = await speech.transcribe(clip, plan: speechPlan, priority: .background)
        // No text: the row keeps its text and status, and nothing starts waiting for it.
        guard case .text = outcome else { return .nothing(id) }
        let cleanupPlan = CleanupPlan.make(preferences: preferences, access: access, terms: words.terms,
                                           rules: words.rules, app: record.app)
        let run = DictationRun(id: id, origin: record.origin, purpose: record.purpose, context: record.app, clip: nil,
                               cleaning: cleanup.begin(plan: cleanupPlan),
                               cleanupDeadline: Self.backgroundCleanupDeadline, access: access, target: nil,
                               releasedAt: nil, previous: record.status, hold: nil)
        return await land(outcome, run)
    }
}
