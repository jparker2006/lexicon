#if DEBUG
import Synchronization
public import LexiconDomain
public import Transcription

/// The `dictate --result-delay` test hook: the local model's next live answer
/// comes late, as a slow model's would, so a check can switch apps, type or
/// press fn while a Dictation is still transcribing. Debug builds only: every
/// debug launch wraps the model in one, inert until a hook runs a Dictation through `slowing`.
public final class SlowedTranscriber: LocalTranscriber {
    private let base: any LocalTranscriber
    private let clock: any Clock<Duration>
    private let next = Mutex<Duration?>(nil)

    public init(_ base: any LocalTranscriber, clock: any Clock<Duration> = ContinuousClock()) {
        self.base = base
        self.clock = clock
    }

    /// Runs `dictation` with the next `.live` session (its fn-down) answering
    /// `delay` after the model does; one that throws spends it too. Recovery and Retry
    /// (`.background`) are never slowed. Disarmed when `dictation` returns,
    /// whatever happened: one that never reached the model (an unreadable file,
    /// a model still loading) must not slow the next real Dictation.
    public func slowing<Value: Sendable>(by delay: Duration, _ dictation: @Sendable () async -> Value) async -> Value {
        next.withLock { $0 = delay }
        defer { next.withLock { $0 = nil } }
        return await dictation()
    }

    public var model: LocalModel { base.model }
    public var isResident: Bool { get async { await base.isResident } }
    public func load() async throws { try await base.load() }
    public func unload() async { await base.unload() }

    public func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        let session = base.session(terms: terms, priority: priority)
        guard priority == .live, let delay = next.withLock({ $0.take() }) else { return session }
        return SlowedSession(base: session, delay: delay, clock: clock)
    }
}

/// The model's session, its text answered `delay` late.
private final class SlowedSession: LocalSession {
    let base: any LocalSession
    let delay: Duration
    let clock: any Clock<Duration>

    init(base: any LocalSession, delay: Duration, clock: any Clock<Duration>) {
        self.base = base
        self.delay = delay
        self.clock = clock
    }

    func append(_ samples: [Int16]) { base.append(samples) }

    func finish(_ clip: AudioClip) async throws -> String {
        let text = try await base.finish(clip)
        try await clock.sleep(for: delay)
        return text
    }

    func cancel() { base.cancel() }
}
#endif
