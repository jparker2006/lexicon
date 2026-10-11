import Foundation
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
    let cloud: CloudLink
    let clock: any Clock<Duration>

    /// `cloud`: `.network` in the app and eval; tests pass a scripted link.
    /// `clock` times the race deadline and the local model's idle unload; tests pass a fake one.
    public init(local: (any LocalTranscriber)?, cloud: CloudLink = .network,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.local = local
        self.cloud = cloud
        self.clock = clock
        let residency = local.map { LocalResidency(transcriber: $0, clock: clock) }
        self.residency = residency
        // While the network is down local is the only engine, so it stays loaded.
        if let residency {
            let changes = cloud.path.changes()
            Task { for await reachable in changes { await residency.networkChanged(reachable: reachable) } }
        }
    }

    /// fn-down. Starts streaming `feed` to the cloud model (when the plan has
    /// one and the network is up) and, if the local model is not resident, starts
    /// loading it now so it is warm by fn-up (warm load 0.4-0.6 s overlaps the
    /// speech). Local work for this attempt runs at `LocalPriority.live`.
    public func begin(feed: AudioFeed, plan: SpeechPlan) -> SpeechAttempt {
        SpeechAttempt(core: AttemptCore(feed: feed, plan: plan, local: local, residency: residency, cloud: cloud,
                                         clock: clock, priority: .live))
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
    /// No `access` (Private mode, an always-private app) or no cloud model: local only.
    public static func make(preferences: Preferences, access: CloudAccess?, terms: [Term],
                            forcing model: SpeechModel? = nil) -> SpeechPlan {
        let local: LocalModel? = switch model {
        case nil: preferences.localModel
        case .local(let forced)?: forced
        case .cloud?: nil
        }
        let cloudModel: CloudModel? = switch model {
        case nil: preferences.cloudModel
        case .cloud(let forced)?: forced
        case .local?: nil
        }
        return SpeechPlan(cloud: access.flatMap { access in cloudModel.map { ($0, access) } }, local: local, terms: Array(terms.prefix(preferences.speechTerms)),
                          race: RacePolicy(deadline: preferences.raceDeadline),
                          residency: ResidencyPolicy(preferences))
    }
}

/// One in-flight transcription. Non-copyable: finished or cancelled at most once.
public struct SpeechAttempt: ~Copyable, Sendable {
    let core: AttemptCore
    /// The cloud provider's text while Jake talks: partials and finalized
    /// segments, in order (`CloudSession` maps `ProviderEvent.partial/.final`).
    /// Finishes when the attempt finishes or is cancelled. Empty (finishes at once)
    /// for a local-only plan: Private mode, offline, or no cloud model, where local transcribes the
    /// whole clip at fn-up and Cleanup then cleans it all at `finish`.
    /// Single consumer: the Conductor hands it to Cleanup. If the indicator later
    /// shows live text (#18), the Conductor fans it out; nothing else subscribes.
    /// Every finalized segment passes `SecretGuard.matches` here, before Cleanup
    /// sees it; a match revokes the plan's `CloudAccess`, which cuts this stream
    /// and leaves the local model to finish (#5).
    public var segments: AsyncStream<SpeechSegment> { core.segments }

    /// fn-up, after the LiveCapture's tail. The provider's finalize goes out as
    /// the feed ends, and the local model races it on `clip` (the RAM copy): the
    /// cloud wins if its text is back within `Preferences.raceDeadline` of this
    /// call, otherwise local does. A cloud that cannot run or fails hands over
    /// to local at once. Never throws: every failure is an outcome.
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
    /// The network was down at fn-down and there is no local text: the Dictation waits for the network.
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
    /// Recording stopped (`SpeechAttempt.finish`) -> the winning text.
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
    let clock: any Clock<Duration>
    /// The plan's cloud model, even when its session could not start, so the
    /// attempts table says why the cloud did not help.
    let cloud: CloudModel?
    /// nil with no cloud model, or with the network down at fn-down.
    let session: CloudSession?
    let segments: AsyncStream<SpeechSegment>
    /// Loads the local model while Jake talks, so fn-up never waits on the load.
    let warmUp: Task<Void, Never>
    /// Hands each captured chunk to the cloud session, and always reads the feed
    /// to its end: the clip is the RAM copy local transcribes, so the feed's own
    /// buffer of the same chunks is dropped as it is read.
    let drain: Task<Void, Never>

    init(feed: AudioFeed, plan: SpeechPlan, local: (any LocalTranscriber)?, residency: LocalResidency?,
         cloud link: CloudLink, clock: any Clock<Duration>, priority: LocalPriority) {
        self.plan = plan
        let local = local.flatMap { $0.model == plan.local ? $0 : nil }
        self.local = local
        self.residency = local == nil ? nil : residency
        self.priority = priority
        self.clock = clock
        cloud = plan.cloud?.model
        let session = plan.cloud.flatMap { cloud in
            link.path.isUp ? CloudSession(model: cloud.model, access: cloud.access, terms: plan.terms, link: link) : nil
        }
        self.session = session
        if let session {
            segments = session.segments
        } else {
            let (segments, ended) = AsyncStream<SpeechSegment>.makeStream()
            ended.finish()
            self.segments = segments
        }
        warmUp = Task { [residency = self.residency] in await residency?.dictationBegan(plan.residency) }
        drain = Task {
            for await chunk in feed { session?.send(chunk) }
            if !Task.isCancelled { session?.audioEnded() }
        }
    }

    private enum Finished: Sendable {
        case cloud(CloudSession.End)
        case local(LocalEnd)
        case deadline
        case giveUp
    }

    private enum LocalEnd: Sendable {
        case text(String)
        case failed(SpeechUnavailable)
    }

    func finish(_ clip: AudioClip) async -> SpeechOutcome {
        let stopped = ContinuousClock.now
        let (events, post) = AsyncStream<Finished>.makeStream()
        if let session { Task { post.yield(.cloud(await session.result)) } }
        let localRun = local.map { local in
            Task {
                await warmUp.value
                post.yield(.local(await transcribe(clip, with: local)))
                await residency?.dictationEnded()
            }
        }
        var timers: [Task<Void, Never>] = []
        if session != nil {
            let clock = clock
            for (wait, event) in [(plan.race.deadline, Finished.deadline), (plan.race.giveUp, .giveUp)] {
                timers.append(Task {
                    do { try await clock.sleep(for: wait) } catch { return }
                    post.yield(event)
                })
            }
        }

        var cloudState: RacePolicy.State? = cloud == nil ? nil : session == nil ? .failed : .pending
        var cloudError: String? = cloud != nil && session == nil ? "offline" : nil
        var localState: RacePolicy.State? = local == nil ? nil : .pending
        var localFailure: SpeechUnavailable?
        var cloudLatency: Duration?, localLatency: Duration?
        var deadlinePassed = false
        var decision = plan.race.decide(cloud: cloudState, local: localState, deadlinePassed: false)
        if decision == .wait {
            for await event in events {
                switch event {
                case .cloud(.text(let text)):
                    cloudState = .done(text)
                    cloudLatency = stopped.duration(to: .now)
                case .cloud(.failed(let error)):
                    cloudState = .failed
                    cloudError = error
                case .local(.text(let text)):
                    localState = .done(text)
                    localLatency = stopped.duration(to: .now)
                case .local(.failed(let reason)):
                    localState = .failed
                    localFailure = reason
                case .deadline:
                    deadlinePassed = true
                case .giveUp:
                    guard cloudState == .pending else { break }
                    cloudState = .failed
                    cloudError = "no answer in \(plan.race.giveUp)"
                }
                decision = plan.race.decide(cloud: cloudState, local: localState, deadlinePassed: deadlinePassed)
                if decision != .wait { break }
            }
        }
        for timer in timers { timer.cancel() }
        post.finish()
        if cloudState == .pending { session?.close() }  // local won: the socket is not needed any more
        if localState == .pending { localRun?.cancel() }  // the cloud won; the hold on the model still ends

        var attempts: [AttemptRecord] = []
        if let cloud {
            let model = SpeechModel.cloud(cloud)
            let record: AttemptRecord = switch cloudState {
            case .done(let text)?: AttemptRecord(model: model, result: .won, text: text, latency: cloudLatency, error: nil)
            case .pending?: AttemptRecord(model: model, result: .timedOut, text: nil, latency: nil, error: nil)
            case .failed?, nil: AttemptRecord(model: model, result: .failed, text: nil, latency: nil, error: cloudError)
            }
            attempts.append(record)
        }
        if let local {
            let model = SpeechModel.local(local.model)
            let record: AttemptRecord = switch localState {
            case .done(let text)?:
                AttemptRecord(model: model, result: decision == .useLocal ? .won : .lost, text: text,
                              latency: localLatency, error: nil)
            case .pending?: AttemptRecord(model: model, result: .cancelled, text: nil, latency: nil, error: nil)
            case .failed?, nil:
                AttemptRecord(model: model, result: .failed, text: nil, latency: nil,
                              error: localFailure.map { String(describing: $0) })
            }
            attempts.append(record)
        }

        let won: (text: String, model: SpeechModel, latency: Duration?)
        switch (decision, cloudState, localState) {
        case (.useCloud, .done(let text)?, _):
            won = (text, .cloud(cloud!), cloudLatency)
        case (.useLocal, _, .done(let text)?):
            won = (text, .local(local!.model), localLatency)
        default:
            if cloud != nil {
                return .unavailable(session == nil ? .offline : .providerError(cloudError ?? "failed"))
            }
            return .unavailable(localFailure ?? .noModel)
        }
        guard won.text.contains(where: { !$0.isWhitespace }) else { return .unavailable(.silence) }
        return .text(SpeechText(text: won.text, model: won.model, finalizeToText: won.latency ?? .zero,
                                attempts: attempts))
    }

    private func transcribe(_ clip: AudioClip, with local: any LocalTranscriber) async -> LocalEnd {
        do {
            return .text(try await local.transcribe(clip, terms: plan.terms, priority: priority))
        } catch is LocalModelNotInstalled {
            return .failed(.noModel)
        } catch {
            return .failed(.localModelFailed(String(describing: error)))
        }
    }

    func cancel() {
        drain.cancel()
        session?.close()
        // Ends this attempt's hold on the model once its fn-down load is done.
        Task { [warmUp, residency] in
            await warmUp.value
            await residency?.dictationEnded()
        }
    }
}
