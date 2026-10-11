import Foundation
import LexiconDomain
import Inbox

// `lexicon`: shipped inside the app bundle (Contents/Helpers/lexicon). Links
// Foundation, LexiconDomain and Inbox only, so it starts in milliseconds and
// returns before Claude Code notices.
//
//   lexicon hook claude-code     # UserPromptSubmit hook: reads hook JSON on stdin
//   lexicon hook codex           # same for Codex
//   lexicon dictate <file.wav>   # dev test hook; the app ignores it unless test hooks are on
//
// It finds the inbox from its own enclosing bundle's id, so the dev build's CLI
// talks to the dev app and the daily build's CLI to the daily app.
// Always exits 0 for hooks: a broken Lexicon must never block a prompt.

enum HookCommand {
    case promptSubmitted(SubmittedPrompt.Source)
    case dictate(path: String)

    static func parse(_ arguments: [String]) -> HookCommand? {
        fatalError("not implemented")
    }
}

func enclosingBundleID() -> String? {
    // TODO: walk up from CommandLine.arguments[0] to the enclosing .app and read its Info.plist.
    fatalError("not implemented")
}

func runCLI() -> Int32 {
    // TODO: parse; build InboxWriter(paths: .forBundle(id: enclosingBundleID() ?? dev id));
    // for hooks: SubmittedPrompt.fromHookInput(stdin, source:, now:) then post; print nothing; return 0.
    fatalError("not implemented")
}

exit(runCLI())
