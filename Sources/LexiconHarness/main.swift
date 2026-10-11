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
           lexicon-harness hook capture <seconds> [prepared[=<idle s>]] [change] [device=<uid>]

      check   launch Lexicon Dev with test hooks, find its status item by identifier,
              list its windows, open the target field, read it and clear it
      hook    send one test hook to the running Lexicon Dev and print the reply
              capture: record from the mic and measure the start gap, tail, file
              and mic release; `prepared` prepares the engine first and waits
              0.3 s (or the idle seconds given) before fn-down, else it is built
              cold on fn-down; `change` rebuilds the engine halfway as a device
              change would
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
    case ("capture", let seconds?, _): capture(seconds: seconds, options: arguments.dropFirst(2))
    default: fail(usage, code: 64)
    }
    var timeout = Duration.seconds(10)
    if case .capture(let seconds, let idle, _, _) = command { timeout += .seconds(seconds + (idle ?? 0)) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    switch try await DevApp.hooks.send(command, timeout: timeout) {
    case .status(let status):
        print(String(decoding: try encoder.encode(status), as: UTF8.self))
    case .capture(let measurement):
        print(String(decoding: try encoder.encode(measurement), as: UTF8.self))
    case .failed(let reason):
        fail("FAIL  \(reason)")
    }
}

func capture(seconds: String, options: ArraySlice<String>) -> TestHookCommand {
    guard let seconds = Double(seconds), seconds > 0 else { fail(usage, code: 64) }
    var change = false
    var prepared, device: String?
    for option in options {
        switch option {
        case "prepared": prepared = "0.3"
        case _ where option.hasPrefix("prepared="): prepared = String(option.dropFirst("prepared=".count))
        case "change": change = true
        case _ where option.hasPrefix("device="): device = String(option.dropFirst("device=".count))
        default: fail(usage, code: 64)
        }
    }
    let idle = prepared.map { Double($0) }
    if idle == .some(nil) { fail(usage, code: 64) }
    return .capture(seconds: seconds, preparedIdle: idle ?? nil, deviceChange: change, deviceUID: device)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "check": try await check()
    case "hook": try await hook(Array(arguments.dropFirst()))
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
