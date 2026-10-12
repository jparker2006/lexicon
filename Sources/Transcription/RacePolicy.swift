import os
import LexiconDomain

/// Cloud vs local once recording stops (`Preferences.raceDeadline`). Pure, so the
/// policy is unit-tested with no clock and no network.
struct RacePolicy: Sendable, Hashable {
    /// After recording stops: wait this long for the cloud final before using local text.
    var deadline: Duration
    /// With no local text to fall back on, how long the cloud may take before the
    /// Dictation waits for the network instead. Every wait has a deadline.
    var giveUp: Duration = .seconds(10)

    /// One engine's state. nil in `decide` means the plan has no such engine.
    enum State: Sendable, Hashable {
        case pending
        case done(String)
        case failed
    }

    enum Decision: Sendable, Equatable {
        case wait
        case useCloud
        case useLocal
        case nothingYet   // both failed: unavailable
    }

    /// The cloud wins whenever its final is back before the deadline, even if
    /// local finished first. A failed cloud, or the deadline passing, hands the
    /// Dictation to local the moment local has text. The caller decides again on
    /// every engine result, so after the deadline whichever engine answers next
    /// wins, and a slow local load can still be beaten by the cloud.
    func decide(cloud: State?, local: State?, deadlinePassed: Bool) -> Decision {
        if case .done? = cloud { return .useCloud }
        if case .done? = local, cloud != .pending || deadlinePassed { return .useLocal }
        if cloud != .pending, local != .pending { return .nothingYet }
        return .wait
    }
}

/// THE local model residency rule, in one place (`Preferences.localModelLinger`).
///
/// - Private mode on, or the network unreachable: ALWAYS resident. Local is then
///   the only engine, so a load on fn-down would sit directly in front of the text.
/// - Otherwise: loaded on fn-down when not resident (the 0.4-0.6 s warm load
///   overlaps speech), kept while Jake dictates, unloaded after
///   `Preferences.localModelLinger` (default 10 minutes) with no Dictation.
///
/// Pure, so it is tested with no model and no network.
struct ResidencyPolicy: Sendable, Hashable {
    var privacy: PrivacyMode
    /// With no cloud model there is nothing to lose when the network drops, so
    /// reachability only counts when one is set.
    var usesCloud: Bool
    var networkReachable = true
    var linger: Duration

    init(_ preferences: Preferences) {
        privacy = preferences.privacy
        usesCloud = preferences.cloudModel != nil
        linger = preferences.localModelLinger
    }

    /// How long after the last Dictation to unload. nil: stay resident.
    var unloadAfter: Duration? {
        privacy == .private || (usesCloud && !networkReachable) ? nil : linger
    }
}

/// Applies `ResidencyPolicy` to the one local model: loads on fn-down if not
/// resident, loads at once when the policy turns "always" (Private mode on,
/// network lost), and unloads once no Dictation has run for the linger time,
/// which returns the process to its idle budget.
actor LocalResidency {
    let transcriber: any LocalTranscriber
    /// Loads and unloads, so idle memory can be read against them.
    private let log = Logger(subsystem: "Lexicon", category: "speech")
    let clock: any Clock<Duration>
    /// Dictations between fn-down and their text. The model never unloads under one.
    private var dictating = 0
    /// From `policyChanged`, the live settings. Once fed, it wins over every
    /// fn-down snapshot, which can be older (Private mode turned on mid-Dictation).
    private var fed: ResidencyPolicy?
    /// The latest fn-down snapshot: the only policy when nothing feeds changes (headless runs).
    private var snapshot: ResidencyPolicy?
    /// From the engine's network path, which applies to whichever policy is current.
    private var networkReachable = true
    private var policy: ResidencyPolicy? {
        guard var policy = fed ?? snapshot else { return nil }
        policy.networkReachable = networkReachable
        return policy
    }
    private var unloadTimer: Task<Void, Never>?
    /// An idle unload under way. Until it is done the model still reads as
    /// resident, so a fn-down waits for it before loading, or its Dictation would
    /// load the model inside the job queue.
    private var unloading: Task<Void, Never>?

    var unloadScheduled: Bool { unloadTimer != nil }

    init(transcriber: any LocalTranscriber, clock: any Clock<Duration>) {
        self.transcriber = transcriber
        self.clock = clock
    }

    /// fn-down: the model stays loaded while this Dictation runs.
    func dictationBegan(_ policy: ResidencyPolicy) {
        snapshot = policy
        dictating += 1
        unloadTimer?.cancel()
        unloadTimer = nil
    }

    /// fn-down's load, after `dictationBegan`. Waits for every idle unload under
    /// way (fn-up bounds that wait, `AttemptCore.loadLimit`). Throws the load's
    /// error, so fn-up answers with it instead of loading again.
    func loadForDictation() async throws {
        // Another unload can start while this waits on one stuck behind a hung call.
        var waited: Task<Void, Never>?
        while let unload = unloading, unload != waited {
            await unload.value
            waited = unload
        }
        if !(await transcriber.isResident) { try await transcriber.load() }
        // Its Dictation ended while it waited, and none holds the model now: the
        // linger that armed when it ended has already run, so start it again. One
        // still armed (or firing) is left alone.
        if dictating == 0, unloadTimer == nil { armUnload() }
    }

    /// Launch: load now if not resident, then follow `policy` (the idle unload),
    /// or a newer one fed while the load ran (a first load takes about 25 s).
    func warm(_ policy: ResidencyPolicy) async {
        if !(await transcriber.isResident) {
            let started = ContinuousClock.now
            do {
                try await transcriber.load()
                let ms = (started.duration(to: .now) / .milliseconds(1)).rounded()
                log.notice("local model loaded at launch in \(Int(ms), privacy: .public) ms")
            } catch {
                log.notice("local model not loaded at launch: \(String(describing: error), privacy: .private)")
            }
        }
        await policyChanged(fed ?? policy)
    }

    /// The Dictation has its text (or was cancelled): start the idle timer.
    func dictationEnded() {
        dictating -= 1
        armUnload()
    }

    /// Private mode toggled or settings changed (SpeechEngine feeds this).
    func policyChanged(_ policy: ResidencyPolicy) async {
        fed = policy
        await apply()
    }

    /// The network went down or came back (SpeechEngine feeds this).
    func networkChanged(reachable: Bool) async {
        guard reachable != networkReachable else { return }
        networkReachable = reachable
        await apply()
    }

    private func apply() async {
        guard let policy else { return }
        if policy.unloadAfter == nil {
            unloadTimer?.cancel()
            unloadTimer = nil
            // Never waits on an unload, which can sit behind a hung model call and would
            // stop the settings and network feeds; `unloadIfIdle` loads again after it.
            if unloading == nil, !(await transcriber.isResident) { try? await transcriber.load() }
        } else {
            armUnload()
        }
    }

    private func armUnload() {
        unloadTimer?.cancel()
        unloadTimer = nil
        guard dictating == 0, let linger = policy?.unloadAfter else { return }
        let clock = clock
        unloadTimer = Task {
            do { try await clock.sleep(for: linger) } catch { return }
            await self.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard dictating == 0, !Task.isCancelled else { return }
        unloadTimer = nil
        let unload = Task { [transcriber] in await transcriber.unload() }
        unloading = unload
        await unload.value
        // A later unload can have started while this one sat behind a hung call; it still runs.
        if unloading == unload { unloading = nil }
        log.notice("local model unloaded: no Dictation for the linger time")
        // Private mode turned on, or the network went down, while it unloaded. With
        // another unload still running, that one loads again when it ends.
        if unloading == nil, policy?.unloadAfter == nil { try? await transcriber.load() }
    }
}
