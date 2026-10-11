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
    let clock: any Clock<Duration>
    /// Dictations between fn-down and their text. The model never unloads under one.
    private var dictating = 0
    private var unloadTimer: Task<Void, Never>?

    init(transcriber: any LocalTranscriber, clock: any Clock<Duration>) {
        self.transcriber = transcriber
        self.clock = clock
    }

    /// fn-down: stop the unload timer and load if not resident.
    func dictationBegan() async {
        dictating += 1
        unloadTimer?.cancel()
        unloadTimer = nil
        if !(await transcriber.isResident) {
            try? await transcriber.load()  // a failed load shows up as a failed transcription
        }
    }

    /// The Dictation has its text (or was cancelled): start the idle timer.
    func dictationEnded(_ policy: ResidencyPolicy) {
        dictating -= 1
        armUnload(policy)
    }

    /// Private mode toggled or reachability changed (SpeechEngine feeds this).
    func policyChanged(_ policy: ResidencyPolicy) async {
        if policy.unloadAfter == nil {
            unloadTimer?.cancel()
            unloadTimer = nil
            if !(await transcriber.isResident) { try? await transcriber.load() }
        } else {
            armUnload(policy)
        }
    }

    private func armUnload(_ policy: ResidencyPolicy) {
        unloadTimer?.cancel()
        unloadTimer = nil
        guard dictating == 0, let linger = policy.unloadAfter else { return }
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
    }
}
