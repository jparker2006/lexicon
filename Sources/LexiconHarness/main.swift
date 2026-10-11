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
           lexicon-harness hook status | dictate <wav> | indicator <state>
           lexicon-harness history [search word]

      check   launch Lexicon Dev with test hooks, find its status item by identifier,
              list its windows, open the target field, read it and clear it
      hook    send one test hook to the running Lexicon Dev and print the reply
      history open the History window from the menu bar and time it, click to copy,
              search, close, and compare memory before and after
    """

func ok(_ line: String) { print("ok    \(line)") }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
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
    let command: TestHookCommand = switch (arguments.first, arguments.dropFirst().first, arguments.count) {
    case ("status", _, 1): .status
    case ("dictate", let wav?, 2): .dictate(wav: URL(filePath: wav).standardizedFileURL.path)
    case ("indicator", let state?, 2): .indicator(state: state)
    default: fail(usage, code: 64)
    }
    switch try await DevApp.hooks.send(command, timeout: .seconds(10)) {
    case .status(let status):
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(status), as: UTF8.self))
    case .failed(let reason):
        fail("FAIL  \(reason)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "check": try await check()
    case "hook": try await hook(Array(arguments.dropFirst()))
    case "history": try await HistoryCheck.run(search: arguments.dropFirst().first)
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
