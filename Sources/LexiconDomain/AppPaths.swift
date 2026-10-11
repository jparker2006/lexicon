public import Foundation

/// The data root. One root per bundle id, so the dev build (every builder's
/// worktree) can never write into the History of Jake's daily copy.
///
/// Only the root is public. Each owner names its own files under it, so no
/// other module can find, let alone open, another owner's files:
///
///     ~/Library/Application Support/<root name>/
///         history.sqlite        History (WAL)
///         audio/<id>.caf        History owns the lifecycle; AudioCapture writes bytes while recording
///         lexicon.sqlite        WordStore
///         inbox/*.json          Inbox (read and deleted by the app)
///         models/               LocalParakeet (586 MB of weights, never in the bundle)
public struct AppPaths: Sendable, Hashable {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// "Lexicon" for the daily bundle id, "Lexicon Dev" for the dev bundle id (#14).
    public static func forBundle(id bundleID: String) -> AppPaths {
        // TODO: map known bundle ids to root names; unknown ids get their own folder named by id.
        fatalError("not implemented")
    }

    /// A throwaway root for tests and `lexicon-eval` runs.
    public static func temporary() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory.appending(path: "lexicon-\(UUID().uuidString)"))
    }
}
