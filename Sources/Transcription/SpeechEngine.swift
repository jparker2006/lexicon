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
    let local: (any LocalTranscriber)?
    let residency: LocalResidency?
    let clock: any Clock<Duration>

    /// How often a waiting Dictation tries again. Nothing announces a local model
    /// installed by another process (`scripts/install-model.sh`), and a missing
    /// model costs one file check to find, so trying is how it is noticed.
    public static let retryInterval: Duration = .seconds(30)

    /// `clock` times the local model's idle unload and a waiting Dictation's
    /// retries; tests pass a fake one.
    public init(local: (any LocalTranscriber)?, session: URLSession = .shared,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.local = local
        self.clock = clock
        residency = local.map { LocalResidency(transcriber: $0, clock: clock) }
    }

    /// fn-down. Starts streaming `feed` to the cloud model (when the plan has
    /// one) and, if the local model is not resident, starts loading it now so it
    /// is warm by fn-up (warm load 0.4-0.6 s overlaps the speech). Local work for
    /// this attempt runs at `LocalPriority.live`.
    public func begin(feed: AudioFeed, plan: SpeechPlan) -> SpeechAttempt {
        SpeechAttempt(core: AttemptCore(feed: feed, plan: plan, local: local, residency: residency, priority: .live))
    }

    /// Whole-clip transcription with the same race: retry, recovery, eval, and a
    /// waiting Dictation once the network returns.
    /// `priority`: `.background` for recovery and Retry, so they queue behind any
    /// live Dictation on the Neural Engine; `.live` when the text may still be typed.
    public func transcribe(_ clip: AudioClip, plan: SpeechPlan, priority: LocalPriority = .background) async -> SpeechOutcome {
        let attempt = SpeechAttempt(core: AttemptCore(feed: clip.replay(), plan: plan, local: local,
                                                      residency: residency, priority: priority))
        return await attempt.finish(clip)
    }

    /// Returns when a Dictation that got no text for `reason` should try again:
    /// after `retryInterval`. The cloud race (#66) adds waking early once the
    /// network returns; until then no plan has a cloud engine to wait for.
    public func untilRetry(after reason: SpeechUnavailable) async {
        try? await clock.sleep(for: Self.retryInterval)
    }

    /// Private mode toggled or settings changed. With reachability (NWPathMonitor,
    /// owned here) this feeds `ResidencyPolicy`: entering Private mode or losing
    /// the network loads the local model now, so the next fn-down never waits on it.
    public func preferencesChanged(_ preferences: Preferences) async {
        await residency?.policyChanged(ResidencyPolicy(preferences))
    }

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
    let residency: ResidencyPolicy

    /// - `forcing`: the Retry model picker. A cloud model in Private mode yields
    ///   a plan with no engine, which finishes as `.unavailable(.privateMode)`.
    ///
    /// Local only until the cloud race lands (#66), which turns on
    /// `cloud = access.flatMap { access in preferences.cloudModel.map { ($0, access) } }`.
    public static func make(preferences: Preferences, access: CloudAccess?, terms: [Term],
                            forcing model: SpeechModel? = nil) -> SpeechPlan {
        let local: LocalModel? = switch model {
        case nil: preferences.localModel
        case .local(let forced)?: forced
        case .cloud?: nil
        }
        return SpeechPlan(cloud: nil, local: local, terms: Array(terms.prefix(preferences.speechTerms)),
                          race: RacePolicy(deadline: preferences.raceDeadline),
                          residency: ResidencyPolicy(preferences))
    }
}

/// One in-flight transcription. Non-copyable: finished or cancelled at most once.
public struct SpeechAttempt: ~Copyable, Sendable {
    let core: AttemptCore
    public var segments: AsyncStream<SpeechSegment> { core.segments }

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

    /// fn-up, after the LiveCapture's tail. Waits for `feed` to end, sends the
    /// provider's finalize, and races the local model on `clip` (the RAM copy).
    /// Never throws: every failure is an outcome.
    public consuming func finish(_ clip: AudioClip) async -> SpeechOutcome {
        await core.finish(clip)
    }

    /// Cancelled or discarded Dictation: close the socket, drop local work.
    public consuming func cancel() { core.cancel() }
}

public enum SpeechOutcome: Sendable {
    case text(SpeechText)
    case unavailable(SpeechUnavailable)
}

public enum SpeechUnavailable: Sendable, Hashable {
    /// Cloud failed twice and there is no local model: the Dictation waits for the network.
    case offline
    /// The cloud provider failed: the Dictation waits for the network.
    case providerError(String)
    /// The local model is installed but failed to load or transcribe. The
    /// Dictation keeps its audio and waits for a working model, not the network.
    case localModelFailed(String)
    /// Private mode and no local model.
    case privateMode
    /// No cloud model in the plan and no local model installed: the Dictation
    /// waits for one.
    case noModel
    case silence

    /// The Dictation keeps its audio and waits for an engine, instead of failing.
    public var waits: Bool {
        switch self {
        case .offline, .providerError, .noModel, .localModelFailed: true
        case .privateMode, .silence: false
        }
    }

    /// Waiting on the network, so the notice says so. A missing or broken local
    /// model waits for a model instead, and the network would not help it.
    public var waitsForNetwork: Bool {
        switch self {
        case .offline, .providerError: true
        case .noModel, .localModelFailed, .privateMode, .silence: false
        }
    }
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
    /// Warm load 0.2-0.6 s. The first load in a new executable or after a macOS
    /// update also compiles for the Neural Engine (about 25 s), so the app must
    /// warm the model at launch, not on a Dictation.
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

/// Thrown by a `LocalTranscriber` whose weights are not on disk: the Dictation
/// waits for a model (`.noModel`) instead of failing.
public struct LocalModelNotInstalled: Error, Sendable {
    public let model: LocalModel
    public init(_ model: LocalModel) { self.model = model }
}

/// Who is waiting on a local transcription. See `LocalTranscriber.transcribe`.
public enum LocalPriority: Sendable, Hashable {
    /// Jake is waiting at the cursor: fn-up of a live or test-hook Dictation.
    case live
    /// Nobody is waiting: launch recovery, manual Retry.
    case background
}

/// One attempt's work, shared by the non-copyable `SpeechAttempt` and its tasks.
final class AttemptCore: Sendable {
    let plan: SpeechPlan
    /// The engine's transcriber, only when it runs the model the plan asks for.
    let local: (any LocalTranscriber)?
    let residency: LocalResidency?
    let priority: LocalPriority
    /// Empty until a cloud plan exists: local transcribes the whole clip at
    /// `finish`, so there is no text while Jake talks.
    let segments: AsyncStream<SpeechSegment>
    /// Loads the local model while Jake talks, so fn-up never waits on the load.
    let warmUp: Task<Void, Never>
    /// The clip is the RAM copy local transcribes; the feed's own buffer of the
    /// same chunks is read and dropped so a long Dictation holds its audio once.
    let drain: Task<Void, Never>

    init(feed: AudioFeed, plan: SpeechPlan, local: (any LocalTranscriber)?, residency: LocalResidency?,
         priority: LocalPriority) {
        self.plan = plan
        let local = local.flatMap { $0.model == plan.local ? $0 : nil }
        self.local = local
        self.residency = local == nil ? nil : residency
        self.priority = priority
        let (segments, ended) = AsyncStream<SpeechSegment>.makeStream()
        ended.finish()
        self.segments = segments
        warmUp = Task { [residency = self.residency] in await residency?.dictationBegan(plan.residency) }
        drain = Task { for await _ in feed {} }
    }

    func finish(_ clip: AudioClip) async -> SpeechOutcome {
        guard let local else { return .unavailable(.noModel) }
        await warmUp.value
        let outcome = await transcribe(clip, with: local)
        await residency?.dictationEnded()
        return outcome
    }

    private func transcribe(_ clip: AudioClip, with local: any LocalTranscriber) async -> SpeechOutcome {
        let model = SpeechModel.local(local.model)
        let started = ContinuousClock.now
        do {
            let text = try await local.transcribe(clip, terms: plan.terms, priority: priority)
            let latency = started.duration(to: .now)
            guard text.contains(where: { !$0.isWhitespace }) else { return .unavailable(.silence) }
            let won = AttemptRecord(model: model, result: .won, text: text, latency: latency, error: nil)
            return .text(SpeechText(text: text, model: model, finalizeToText: latency, attempts: [won]))
        } catch is LocalModelNotInstalled {
            return .unavailable(.noModel)
        } catch {
            return .unavailable(.localModelFailed(String(describing: error)))
        }
    }

    func cancel() {
        drain.cancel()
        // Ends this attempt's hold on the model once its fn-down load is done.
        Task { [warmUp, residency] in
            await warmUp.value
            await residency?.dictationEnded()
        }
    }
}
