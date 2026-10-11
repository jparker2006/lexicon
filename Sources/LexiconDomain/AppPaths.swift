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

    /// Jake's daily copy, installed by `scripts/install.sh`.
    public static let dailyBundleID = "dev.jparker.lexicon"
    /// Every builder's build, installed by `scripts/dev-run.sh`.
    public static let devBundleID = "dev.jparker.lexicon.dev"

    /// "Lexicon" for the daily bundle id, "Lexicon Dev" for the dev bundle id.
    /// Any other id gets a folder named by the id, never the daily one.
    public static func forBundle(
        id bundleID: String,
        in applicationSupport: URL = URL.applicationSupportDirectory
    ) -> AppPaths {
        // Reverse-DNS only, so an unknown id can never be named "Lexicon".
        precondition(bundleID.contains(".") && !bundleID.contains("/"), "not a bundle id: \(bundleID)")
        let name = switch bundleID {
        case dailyBundleID: "Lexicon"
        case devBundleID: "Lexicon Dev"
        default: bundleID
        }
        return AppPaths(root: applicationSupport.appending(path: name, directoryHint: .isDirectory))
    }

    /// A throwaway root for tests and `lexicon-eval` runs.
    public static func temporary() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory.appending(path: "lexicon-\(UUID().uuidString)"))
    }
}
