#if DEBUG
import Synchronization
public import LexiconDomain
public import Transcription

/// The `dictate --result-delay` test hook: the local model's next live answer
/// comes late, as a slow model's would, so a check can switch apps, type or
/// press fn while a Dictation is still transcribing. Debug builds only: the
/// dev app wraps its model in one only when launched with test hooks.
public final class SlowedTranscriber: LocalTranscriber {
    private let base: any LocalTranscriber
    private let clock: any Clock<Duration>
    private let next = Mutex<Duration?>(nil)

    public init(_ base: any LocalTranscriber, clock: any Clock<Duration> = ContinuousClock()) {
        self.base = base
        self.clock = clock
    }

    /// The next `.live` transcription answers `delay` after the model does.
    /// Recovery and Retry (`.background`) are never slowed.
    public func slowNext(by delay: Duration) { next.withLock { $0 = delay } }

    public var model: LocalModel { base.model }
    public var isResident: Bool { get async { await base.isResident } }
    public func load() async throws { try await base.load() }
    public func unload() async { await base.unload() }

    public func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) async throws -> String {
        let text = try await base.transcribe(clip, terms: terms, priority: priority)
        if priority == .live, let delay = next.withLock({ $0.take() }) { try await clock.sleep(for: delay) }
        return text
    }
}
#endif
