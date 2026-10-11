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

    /// Should the model be resident `idle` after the last Dictation ended?
    func keepResident(idle: Duration) -> Bool {
        // TODO: privacy == .private || !networkReachable || idle < linger
        fatalError("not implemented")
    }
}

/// Applies `ResidencyPolicy` to the one local model: loads on fn-down if not
/// resident, loads at once when the policy turns "always" (Private mode on,
/// network lost), schedules the unload otherwise. Returns the process to its
/// idle budget when the policy allows.
actor LocalResidency {
    let transcriber: any LocalTranscriber
    init(transcriber: any LocalTranscriber) { self.transcriber = transcriber }

    /// fn-down: load if not resident, then re-arm the unload timer under `policy`.
    func dictationBegan(_ policy: ResidencyPolicy) async { fatalError("not implemented") }

    /// Private mode toggled or reachability changed (SpeechEngine feeds this).
    func policyChanged(_ policy: ResidencyPolicy) async { fatalError("not implemented") }
}
