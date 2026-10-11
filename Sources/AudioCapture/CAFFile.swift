public import Foundation
public import LexiconDomain

/// CAF format knowledge for files this module wrote. Used by History during
/// recovery and retry; History never parses audio itself.
public enum CAFFile {
    public enum State: Sendable, Hashable {
        /// Header says data size -1: the writer never closed it (crash or power loss).
        case open
        case closed
        case unreadable
    }

    public static func state(of url: URL) -> State { fatalError("not implemented") }

    /// Reopens a crashed CAF read-write and closes it, which writes the real size
    /// (CAF spec: a -1 data chunk must be last; readers may fix the size). 1.5 ms.
    /// Idempotent: finalizing a closed file is a no-op.
    public static func finalize(_ url: URL) throws { fatalError("not implemented") }

    /// Reads a 16 kHz mono Int16 CAF into RAM for retry, recovery and eval.
    public static func read(_ url: URL) throws -> AudioClip { fatalError("not implemented") }
}
