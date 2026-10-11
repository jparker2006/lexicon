public import Foundation
public import LexiconDomain

/// Audio in, text out, for every model, every origin.
///
/// Hides: one WebSocket per Dictation opened at fn-down (cold TLS 95-635 ms runs
/// while Jake talks), the provider's session-start message with keywords, PCM
/// framing, manual finalize, parsing finals, retry-once, racing the local model
/// on the same audio against a deadline, NWPathMonitor and "wait for the
/// network", and loading/unloading the local model. Callers never see a socket,
/// a provider message or a model file.
///
/// One engine path: `transcribe(clip:plan:)` is `begin(feed: clip.replay())`
/// followed by `finish`. Retry, recovery and eval cannot drift from live.
public actor SpeechEngine {
    public init(local: (any LocalTranscriber)?, session: URLSession = .shared) {
        fatalError("not implemented")
    }

    /// fn-down. Starts streaming `feed` to the cloud model (when the plan has
    /// one) and, if the local model is not resident, starts loading it now so it
    /// is warm by fn-up (warm load 0.4-0.6 s overlaps the speech). Local work for
    /// this attempt runs at `LocalPriority.live`.
    public func begin(feed: AudioFeed, plan: SpeechPlan) -> SpeechAttempt {
        fatalError("not implemented")
    }

    /// Whole-clip transcription with the same race: retry, recovery, eval, and a
    /// waiting Dictation once the network returns.
    /// `priority`: `.background` for recovery and Retry, so they queue behind any
    /// live Dictation on the Neural Engine; `.live` when the text may still be typed.
    public func transcribe(_ clip: AudioClip, plan: SpeechPlan, priority: LocalPriority = .background) async -> SpeechOutcome {
        // TODO: same body as begin(feed: clip.replay(), plan: plan) with local work at `priority`; then finish(clip)
        fatalError("not implemented")
    }

    /// Private mode toggled or settings changed. With reachability (NWPathMonitor,
    /// owned here) this feeds `ResidencyPolicy`: entering Private mode or losing
    /// the network loads the local model now, so the next fn-down never waits on it.
    public func preferencesChanged(_ preferences: Preferences) { fatalError("not implemented") }

    /// Returns when the network path is satisfied (NWPathMonitor). Used by the
    /// Conductor's "waiting" Dictations (#4, M1).
    public func networkReturned() async { fatalError("not implemented") }
}

/// What to run for one Dictation. Built only through `make`, so race policy
/// (which engines, which deadline) is decided here, not by callers.
public struct SpeechPlan: Sendable {
    let cloud: (model: CloudModel, access: CloudAccess)?
    let local: LocalModel?
    let terms: [Term]
    let race: RacePolicy

    /// - `forcing`: the Retry model picker. A cloud model in Private mode yields
    ///   a plan with no engine, which finishes as `.unavailable(.privateMode)`.
    public static func make(preferences: Preferences, access: CloudAccess?, terms: [Term],
                            forcing model: SpeechModel? = nil) -> SpeechPlan {
        fatalError("not implemented")
    }
}

/// One in-flight transcription. Non-copyable: finished or cancelled at most once.
public struct SpeechAttempt: ~Copyable, Sendable {
    let core: AttemptCore

    /// The cloud provider's text while Jake talks: partials and finalized
    /// segments, in order (`CloudSession` maps `ProviderEvent.partial/.final`).
    /// Finishes when the attempt finishes or is cancelled. Empty (finishes at once)
    /// for a local-only plan: Private mode or offline, where local transcribes the
    /// whole clip at fn-up and Cleanup then cleans it all at `finish`.
    /// Single consumer: the Conductor hands it to Cleanup. If the indicator later
    /// shows live text (#18), the Conductor fans it out; nothing else subscribes.
    /// Every finalized segment passes `SecretGuard.matches` here, before Cleanup
    /// sees it; a match revokes the plan's `CloudAccess`, which cuts this stream
    /// and leaves the local model to finish (#5).
    public let segments: AsyncStream<SpeechSegment>

    /// fn-up, after the LiveCapture's tail. Waits for `feed` to end, sends the
    /// provider's finalize, and races the local model on `clip` (the RAM copy).
    /// Never throws: every failure is an outcome.
    public consuming func finish(_ clip: AudioClip) async -> SpeechOutcome {
        fatalError("not implemented")
    }

    /// Cancelled or discarded Dictation: close the socket, drop local work.
    public consuming func cancel() { fatalError("not implemented") }
}

public enum SpeechOutcome: Sendable {
    case text(SpeechText)
    case unavailable(SpeechUnavailable)
}

public enum SpeechUnavailable: Sendable, Hashable {
    /// Cloud failed twice and there is no local model: the Dictation waits for the network.
    case offline
    case providerError(String)
    /// Private mode and no local model.
    case privateMode
    case silence
}

/// The winning model's text for a Dictation, plus every engine's attempt.
public struct SpeechText: Sendable {
    public let text: String
    public let model: SpeechModel
    /// Finalize sent -> winning final received.
    public let finalizeToText: Duration
    /// Every engine that ran, winner and losers, for the attempts table: both
    /// cloud and local text for every Dictation, free data for #19 and the Test set.
    public let attempts: [AttemptRecord]
}

/// The seam for on-device models. The real adapter lives in `LocalParakeet`
/// (the only target that imports FluidAudio).
public protocol LocalTranscriber: Sendable {
    var model: LocalModel { get }
    var isResident: Bool { get async }
    /// Warm load 0.4-0.6 s. The one-time CoreML compile (~27 s) happens at model
    /// install, never here.
    func load() async throws
    func unload() async
    /// ~80 ms for a clip of 6 s or less. `terms` may be ignored: FluidAudio
    /// boosting hurt accuracy, so the local path relies on Rules after transcription.
    ///
    /// One job at a time on the Neural Engine. A `.live` call goes ahead of every
    /// queued `.background` call (recovery, Retry), so a live Dictation never
    /// waits behind them; a running background job is not aborted (~80 ms).
    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) async throws -> String
}

/// Who is waiting on a local transcription. See `LocalTranscriber.transcribe`.
public enum LocalPriority: Sendable, Hashable {
    /// Jake is waiting at the cursor: fn-up of a live or test-hook Dictation.
    case live
    /// Nobody is waiting: launch recovery, manual Retry.
    case background
}

final class AttemptCore: Sendable {}
