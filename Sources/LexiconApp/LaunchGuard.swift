import Foundation

/// Refuses to run the app when it was not launched by launchd (Finder, `open`,
/// login item: parent pid 1). Best effort: it stops the easy mistake, running
/// the binary from a shell, not a process that sets out to look launchd-started.
///
/// Why: a binary run straight from a shell inherits the shell host's
/// Accessibility trust (Terminal's, an agent's). Its event tap would then work
/// or fail for the wrong reason, and a grant made for it would land on the
/// wrong app. So a shell-launched Lexicon exits before AppKit starts, and never
/// installs the tap. It prints to stderr rather than showing an alert, so an
/// agent's shell gets the message instead of hanging on a modal.
enum LaunchGuard {
    static func refuseUnlessLaunchedByLaunchd() {
        guard getppid() != 1 else { return }
        let app = Bundle.main.bundlePath.hasSuffix(".app")
            ? Bundle.main.bundlePath : NSHomeDirectory() + "/Applications/Lexicon Dev.app"
        FileHandle.standardError.write(Data("""
            Lexicon must be launched by launchd, not from a shell: a shell-launched binary \
            inherits the shell's Accessibility trust. Run scripts/dev-run.sh, or: open "\(app)"

            """.utf8))
        exit(EX_USAGE)
    }
}
