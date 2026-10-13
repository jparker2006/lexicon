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
///         test-hooks/           TestHooks: harness requests and app replies (dev builds only;
///                               always the dev app's own root, also in a scratch run)
///         models/               LocalParakeet (about 614 MB of weights, never in the bundle)
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
        // Reverse-DNS only, so an unknown id can never be named "Lexicon" or climb out with "..".
        precondition(bundleID.contains(".") && !bundleID.hasPrefix(".") && !bundleID.contains("/"),
                     "not a bundle id: \(bundleID)")
        let name = switch bundleID {
        case dailyBundleID: "Lexicon"
        case devBundleID: "Lexicon Dev"
        default: bundleID
        }
        return AppPaths(root: applicationSupport.appending(path: name, directoryHint: .isDirectory))
    }

    /// The root of a test-hooks run of the dev app: synthetic History, audio
    /// and Lexicon go to a scratch folder under the temporary folder, never into
    /// the dev app's own data. It outlives a relaunch, so a check can relaunch
    /// and still find its Dictations. Debug builds only use it.
    public static func scratch(
        forBundle bundleID: String,
        in temporary: URL = FileManager.default.temporaryDirectory
    ) -> AppPaths {
        let name = forBundle(id: bundleID).root.lastPathComponent
        return AppPaths(root: temporary.appending(path: "\(name) scratch", directoryHint: .isDirectory))
    }

    /// A throwaway root for tests and `lexicon-eval` runs.
    public static func temporary() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory.appending(path: "lexicon-\(UUID().uuidString)"))
    }
}
