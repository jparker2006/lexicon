import Synchronization

/// "Has Jake typed or clicked since X?" (#6, #7). Written only by the event-tap
/// thread (`tick` is internal to this module: nobody else can write it), read by
/// AppText (late text, Ghostty Re-speak) and Fixes (Hand fix hints). Lock-free.
/// Counts events, never records which keys: no keystroke logging.
public final class InputClock: Sendable {
    private let counter = Atomic<UInt64>(0)

    public init() {}

    public func mark() -> InputMark { InputMark(value: counter.load(ordering: .acquiring)) }

    public func hasInput(since mark: InputMark) -> Bool {
        counter.load(ordering: .acquiring) != mark.value
    }

    /// Tap thread only: a key-down or mouse-down not posted by Lexicon itself.
    func tick() { counter.add(1, ordering: .releasing) }
}

public struct InputMark: Sendable, Hashable {
    let value: UInt64
}
