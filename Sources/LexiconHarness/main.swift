import Foundation

// lexicon-harness: proves live-app behavior on the installed Lexicon Dev. It
// launches the dev app with `open` and `--test-hooks`, asks it things through
// test hooks, and reads its status item, its windows and a target text field
// through the Accessibility API. Run it with scripts/harness.sh, from a shell
// whose app has the Accessibility grant (the harness inherits it). It drives the
// live app, so only the live-app lane's holder runs it (scripts/live-lane.sh).
//
// One file per subcommand. Output never holds dictated or typed text: only
// counts, timings, outcomes, and text as its length and hash (`Fingerprint`).
#if DEBUG
import AppKit
import LexiconDomain
import TestHooks

let usage = """
    usage: lexicon-harness check | paste-check
           lexicon-harness hook status | dictate <wav> [--result-delay <ms>] | indicator <state> [message] | sound <cue>
           lexicon-harness hook fn down|up... [--shift] | key esc | sleep | mic zeros | audio drops
           lexicon-harness hook insert [--delay <seconds>] <text>
           lexicon-harness hook capture <seconds> [prepared[=<idle s>]] [change] [device=<uid>]
           lexicon-harness hook privacy on|off [--always-private <bundle id>[,<bundle id>...]]
           lexicon-harness pill [--shots <dir>]
           lexicon-harness history [search word]
           lexicon-harness settings [inspect | --release --surface settings|history --head <SHA> --out <file> --runs <n>]
           lexicon-harness relaunch [--release] [--test-hooks [--dev-data] [--short-cap]]
           lexicon-harness wait-fn [--count <n>] [--timeout <seconds>]
           lexicon-harness fixture <text>
           lexicon-harness stats <file>
           lexicon-harness run-checklist <file>
           lexicon-harness result <issue> <branch> <sha>

      check   launch Lexicon Dev with test hooks, find its status item by identifier,
              list its windows, open the target field, read it and clear it
      paste-check  focus the target field, paste a sentence into it through the real
              paste path, then check the field reads it and the clipboard is restored
      hook    send one test hook to the running Lexicon Dev and print the reply
              states: hidden held handsfree warning finishing landed paste error
              cues:   start stop warning error
              dictate: --result-delay holds the local model's answer that many ms
              fn, key: pressed through the fn tap's own handler, in order, back to
              back (so `fn down up down` is a double tap); --shift holds Shift
              sleep: the Mac is going to sleep. mic zeros: the next Dictation's
              mic delivers only zeros. audio drops: the next Dictation (fn or
              dictate) loses its first block, as a ring overflow does
              insert: paste <text> at the focused field after --delay seconds (default 0)
              capture: record from the mic and measure the start gap, tail, file
              and mic release; `prepared` prepares the engine first and waits
              0.3 s (or the idle seconds given) before fn-down, else it is built
              cold on fn-down; `change` rebuilds the engine halfway as a device
              change would
              privacy: turn Private mode on or off. --always-private replaces the
              always-private apps; an empty value (--always-private "") clears them.
              Prints the status, with the privacy mode and the list
      pill    show each indicator state on Lexicon Dev and check the pill, the menu bar
              icon and the focus; then play each sound and time it. --shots <dir> saves
              a picture of the pill and the menu bar icon for each state
      history open the History window from the menu bar and time it, click to copy,
              search, close, and compare memory before and after
      settings with no options, use the fixed .jev Dev fixture. Release mode attaches
              to the running app and records a first show plus repeated show samples
      relaunch  quit Lexicon Dev as Quit does (a Dictation lands first), open it again
              and print its launch timings. --release: the installed copy must be a
              release build. --test-hooks: with hooks, data in a scratch folder unless
              --dev-data; --short-cap: the 20-minute cap is 20 s, its warning at 15 s
      wait-fn print each Dictation's outcome and lag from Lexicon Dev's log as it
              lands, until --count of them (default 1) or --timeout (default 120 s)
      fixture speak <text> into a 16 kHz WAV for `hook dictate`; prints its path
      stats   n, p50, p95 and max (nearest rank) of a sample: each line's first
              number in ms, or a line that is only a number
      run-checklist  run a checklist file's items, print the result table and a
              `Live checks:` comment body
      result  the `Live checks:` comment body for the last run-checklist
    """

func ok(_ line: String) { print("ok    \(line)") }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

/// A duration in milliseconds, one decimal place.
func milliseconds(_ duration: Duration) -> String {
    let parts = duration.components
    let ms = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    return String(format: "%.1f", ms)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let rest = Array(arguments.dropFirst())
do {
    switch arguments.first {
    case "check": try await check()
    // These post input, Dev's Cmd-V or History's own keys: idle skips their windows.
    case "hook" where ["dictate", "insert"].contains(rest.first): try await PostedInput.during { try await hook(rest) }
    case "hook": try await hook(rest)
    case "pill": try await pill(rest)
    case "paste-check": try await PostedInput.during { try await pasteCheck() }
    case "history": try await PostedInput.during { try await HistoryCheck.run(search: rest.first) }
    case "settings": try await PostedInput.during { try await SettingsCheck.run(rest) }
    case "relaunch": try await relaunch(rest)
    case "wait-fn": try await waitFn(rest)
    case "fixture": try await fixture(rest)
    case "stats": try stats(rest)
    case "run-checklist": try await runChecklist(rest)
    case "result": try result(rest)
    case TargetField.mode: TargetField.serve(text: rest.first ?? "", focused: rest.dropFirst().first == "focused")
    default: fail(usage, code: 64)
    }
} catch TestHookError.noReply {
    fail("FAIL  no reply: Lexicon Dev is not running with test hooks. Run: scripts/dev-run.sh -- --test-hooks")
} catch {
    fail("FAIL  \(error)")
}
#else
FileHandle.standardError.write(Data("lexicon-harness is a debug build only: run scripts/harness.sh\n".utf8))
exit(1)
#endif
