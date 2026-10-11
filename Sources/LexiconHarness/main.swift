import Foundation

// lexicon-harness: proves live-app behavior on the installed Lexicon Dev. It
// launches the dev app with `open` and `--test-hooks`, asks it things through
// test hooks, and reads its status item, its windows and a target text field
// through the Accessibility API. Run it with scripts/harness.sh, from a shell
// whose app has the Accessibility grant (the harness inherits it). One builder
// at a time: it drives the live app.
#if DEBUG
import LexiconDomain
import TestHooks

let usage = """
    usage: lexicon-harness check
           lexicon-harness hook status | dictate <wav> | indicator <state> [message] | sound <cue>
           lexicon-harness pill [--shots <dir>]

      check   launch Lexicon Dev with test hooks, find its status item by identifier,
              list its windows, open the target field, read it and clear it
      hook    send one test hook to the running Lexicon Dev and print the reply
              states: hidden held handsfree warning finishing landed paste error
              cues:   start stop warning error
      pill    show each indicator state on Lexicon Dev and check the pill, the menu bar
              icon and the focus; then play each sound and time it. --shots <dir> saves
              a picture of the pill and the menu bar icon for each state
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

@MainActor
func check() async throws {
    try AX.start()
    let app = try await DevApp.launch()
    let status = app.status
    ok("Lexicon Dev \(status.version) answers test hooks (pid \(status.pid), accessibility=\(status.accessibility), microphone=\(status.microphone))")
    _ = try await app.statusItem()
    ok("status item found by identifier \(AccessibilityID.statusItem)")
    let windows = app.windows()
    ok("windows: \(windows.isEmpty ? "none open" : windows.joined(separator: ", "))")

    let text = "lexicon harness \(UUID().uuidString.prefix(8))"
    let target = try await TargetField.open(text: text)
    defer { target.close() }
    guard try target.text() == text else { throw HarnessError("the target field reads \(try target.text().debugDescription), not \(text.debugDescription)") }
    ok("target field reads \(text.debugDescription)")
    try target.clear()
    guard try target.text().isEmpty else { throw HarnessError("the target field still reads \(try target.text().debugDescription) after clearing") }
    ok("target field cleared")
}

func hook(_ arguments: [String]) async throws {
    switch try await DevApp.hooks.send(hookCommand(arguments), timeout: .seconds(10)) {
    case .status(let status):
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(status), as: UTF8.self))
    case .done:
        print("ok")
    case .soundPlayed(let latency):
        print("played in \(milliseconds(latency)) ms")
    case .failed(let reason):
        fail("FAIL  \(reason)")
    }
}

/// The command a `hook` line asks for. A bad line prints the usage.
func hookCommand(_ arguments: [String]) -> TestHookCommand {
    switch arguments.first ?? "" {
    case "status" where arguments.count == 1:
        return .status
    case "dictate" where arguments.count == 2:
        return .dictate(wav: URL(filePath: arguments[1]).standardizedFileURL.path)
    case "indicator" where arguments.count == 2 || arguments.count == 3:
        guard let state = indicatorState(named: arguments[1], message: arguments.count == 3 ? arguments[2] : nil) else {
            fail(usage, code: 64)
        }
        return .indicator(state)
    case "sound" where arguments.count == 2:
        guard let cue = SoundCue(rawValue: arguments[1]) else { fail(usage, code: 64) }
        return .sound(cue)
    default:
        fail(usage, code: 64)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "check": try await check()
    case "hook": try await hook(Array(arguments.dropFirst()))
    case "pill": try await pill(Array(arguments.dropFirst()))
    case TargetField.mode: TargetField.serve(text: arguments.dropFirst().first ?? "")
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
