import os
import LexiconDomain

/// Cloud vs local once recording stops (`Preferences.raceDeadline`). Pure, so the
/// policy is unit-tested with fake timings and no network.
struct RacePolicy: Sendable, Hashable {
    /// After recording stops: wait this long for the cloud final before using local text.
    var deadline: Duration
    /// Cloud attempt retries once before giving up (#4).
    var cloudRetries: Int = 1

    enum State: Sendable {
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

    /// Cloud wins whenever it is back before the deadline. After the deadline,
    /// the first finished engine wins. Local-only plans use local immediately.
    func decide(cloud: State?, local: State?, sinceFinalize: Duration) -> Decision {
        fatalError("not implemented")
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
    var networkReachable: Bool
    var linger: Duration

    /// Reachability is not watched until the cloud race lands (#66): with no
    /// cloud engine there is nothing to lose, so the network counts as up.
    init(_ preferences: Preferences, networkReachable: Bool = true) {
        privacy = preferences.privacy
        self.networkReachable = networkReachable
        linger = preferences.localModelLinger
    }

    /// How long after the last Dictation to unload. nil: stay resident.
    var unloadAfter: Duration? {
        privacy == .private || !networkReachable ? nil : linger
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
    private var policy: ResidencyPolicy? { fed ?? snapshot }
    private var unloadTimer: Task<Void, Never>?

    var unloadScheduled: Bool { unloadTimer != nil }

    init(transcriber: any LocalTranscriber, clock: any Clock<Duration>) {
        self.transcriber = transcriber
        self.clock = clock
    }

    /// fn-down: stop the unload timer and load if not resident.
    func dictationBegan(_ policy: ResidencyPolicy) async {
        snapshot = policy
        dictating += 1
        unloadTimer?.cancel()
        unloadTimer = nil
        if !(await transcriber.isResident) {
            try? await transcriber.load()  // a failed load shows up as a failed transcription
        }
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

    /// Private mode toggled or reachability changed (SpeechEngine feeds this).
    func policyChanged(_ policy: ResidencyPolicy) async {
        fed = policy
        if policy.unloadAfter == nil {
            unloadTimer?.cancel()
            unloadTimer = nil
            if !(await transcriber.isResident) { try? await transcriber.load() }
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
        await transcriber.unload()
        log.notice("local model unloaded: no Dictation for the linger time")
    }
}
