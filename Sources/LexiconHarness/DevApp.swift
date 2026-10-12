#if DEBUG
import AppKit
import LexiconDomain
import TestHooks

/// Lexicon Dev as the harness sees it: launched with `open`, answering test
/// hooks, read through Accessibility. Only ever the dev bundle id: nothing here
/// can name, launch or read Jake's daily copy.
@MainActor
struct DevApp {
    static let installed = URL.homeDirectory.appending(path: "Applications/Lexicon Dev.app")
    static let hooks = TestHookChannel(paths: AppPaths.forBundle(id: AppPaths.devBundleID))

    let status: TestHookStatus
    var element: AXUIElement { AX.app(status.pid) }

    /// The running dev app with test hooks on. Launches the installed copy with
    /// `open` when it is not running; never quits or replaces a running one.
    static func launch() async throws -> DevApp {
        let wasRunning = isRunning
        if !wasRunning {
            guard FileManager.default.fileExists(atPath: installed.path) else {
                throw HarnessError("Lexicon Dev is not installed. Run: scripts/dev-run.sh -- --test-hooks")
            }
            try await run("/usr/bin/open", ["-g", installed.path, "--args", TestHookChannel.launchArgument])
        }
        let reply: TestHookReply
        do {
            // A fresh launch needs a moment before it answers.
            reply = try await hooks.send(.status, timeout: .seconds(wasRunning ? 3 : 15))
        } catch TestHookError.noReply {
            throw HarnessError(isRunning
                ? "Lexicon Dev is running without test hooks. Relaunch it with them: scripts/dev-run.sh -- --test-hooks"
                : "Lexicon Dev did not start")
        }
        guard case .status(let status) = reply, status.bundleID == AppPaths.devBundleID else {
            throw HarnessError("unexpected status reply: \(reply)")
        }
        return DevApp(status: status)
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.devBundleID).isEmpty
    }

    /// The menu bar icon, found by its identifier among the app's menu bar extras.
    /// The status item can lag the hook server by a moment at launch.
    func statusItem() async throws -> AXUIElement {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let extras = AX.element(element, "AXExtrasMenuBar"),
               let item = AX.find(AccessibilityID.statusItem, in: [extras]) {
                return item
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError("no element with identifier \(AccessibilityID.statusItem) in Lexicon Dev's menu bar extras")
    }

    /// Each open window as "title [identifier]".
    func windows() -> [String] {
        AX.elements(element, kAXWindowsAttribute).map { window in
            let title = AX.string(window, kAXTitleAttribute) ?? ""
            return "\"\(title)\" [\(AX.string(window, kAXIdentifierAttribute) ?? "no identifier")]"
        }
    }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
