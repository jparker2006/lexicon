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

    /// Runs `dictation` with the next `.live` transcription answering `delay`
    /// after the model does; one that throws spends it too. Recovery and Retry
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

    public func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) async throws -> String {
        let delay = priority == .live ? next.withLock { $0.take() } : nil
        let text = try await base.transcribe(clip, terms: terms, priority: priority)
        if let delay { try await clock.sleep(for: delay) }
        return text
    }
}
#endif
