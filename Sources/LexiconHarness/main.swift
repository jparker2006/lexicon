import Foundation

// lexicon-harness: proves live-app behavior on the installed Lexicon Dev. It
// launches the dev app with `open` and `--test-hooks`, asks it things through
// test hooks, and reads its status item, its windows and a target text field
// through the Accessibility API. Run it with scripts/harness.sh, from a shell
// whose app has the Accessibility grant (the harness inherits it). One builder
// at a time: it drives the live app.
#if DEBUG
import AppKit
import LexiconDomain
import TestHooks

let usage = """
    usage: lexicon-harness check | paste-check
           lexicon-harness hook status | dictate <wav> | indicator <state> | insert [--delay <seconds>] <text>

      check        launch Lexicon Dev with test hooks, find its status item by identifier,
                   list its windows, open the target field, read it and clear it
      paste-check  focus the target field, paste a sentence into it through the real
                   paste path, then check the field reads it and the clipboard is restored
      hook         send one test hook to the running Lexicon Dev and print the reply
                   (insert pastes <text> at the focused field after --delay seconds, default 0)
    """

func ok(_ line: String) { print("ok    \(line)") }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

/// Pretty-printed with sorted keys, so two runs diff cleanly.
func printJSON<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
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

@MainActor
func pasteCheck() async throws {
    try AX.start()
    let app = try await DevApp.launch()
    let status = app.status
    ok("Lexicon Dev \(status.version) answers test hooks (pid \(status.pid), accessibility=\(status.accessibility), microphone=\(status.microphone))")

    // Cmd-V goes to the focused field of the frontmost app, so the target must take focus.
    let target = try await TargetField.open(text: "", focused: true)
    defer { target.close() }
    // Activation is cooperative: an app started in the background can't take focus
    // from the frontmost one by itself, so System Events brings it forward.
    let raise = Process()
    raise.executableURL = URL(filePath: "/usr/bin/osascript")
    raise.arguments = ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(target.process.processIdentifier)) to true"]
    try raise.run()
    raise.waitUntilExit()
    let focusDeadline = ContinuousClock.now + .seconds(2)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.process.processIdentifier {
        guard ContinuousClock.now < focusDeadline else { throw HarnessError("the target field did not become the frontmost app within 2 s, so Cmd-V would not reach it") }
        try await Task.sleep(for: .milliseconds(50))
    }
    ok("target field is frontmost")

    // A sentinel on the clipboard: after the paste, Lexicon must have put it back.
    // Whatever Jake had copied is put back when the check ends, never printed.
    let pasteboard = NSPasteboard.general
    let jakes = (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
        pasteboard.clearContents()
        pasteboard.writeObjects(jakes.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        })
    }
    let sentinel = "lexicon-harness clipboard \(UUID().uuidString.prefix(8))"
    pasteboard.clearContents()
    pasteboard.setString(sentinel, forType: .string)
    let count = pasteboard.changeCount

    let text = "Lexicon paste check \(UUID().uuidString.prefix(8))"
    let reply = try await DevApp.hooks.send(.insert(text: text, delay: 0), timeout: .seconds(10))
    switch reply {
    case .inserted(let insertion):
        let paste = insertion.pasteWorkMicros.map { "\($0) us" } ?? "none"
        ok("insert reply: \(insertion.outcome), target \(insertion.targetMicros) us, paste \(paste), clipboard access \(insertion.clipboardAccessBefore) -> \(insertion.clipboardAccessAfter)")
        guard insertion.outcome == "inserted" else { throw HarnessError("Lexicon did not insert: \(insertion.outcome)") }
    case .failed(let reason):
        throw HarnessError(reason)
    case .status:
        throw HarnessError("unexpected reply to insert: \(reply)")
    }

    let readDeadline = ContinuousClock.now + .seconds(1)
    while try target.text() != text {
        guard ContinuousClock.now < readDeadline else { throw HarnessError("the target field reads \(try target.text().debugDescription), not \(text.debugDescription)") }
        try await Task.sleep(for: .milliseconds(50))
    }
    ok("target field reads the pasted text")

    // Lexicon restores the clipboard 200 ms after the paste is read; 1 s leaves room on a slow machine.
    try await Task.sleep(for: .seconds(1))
    let held = pasteboard.string(forType: .string)
    let wrote = pasteboard.changeCount != count
    // Says what the clipboard holds without printing it: it can be text Jake copied himself.
    let holds = switch held {
    case sentinel?: "the sentinel"
    case text?: "the pasted text"
    case let other?: "\(other.count) characters"
    case nil: "no string"
    }
    guard wrote, held == sentinel else {
        throw HarnessError(wrote ? "the clipboard holds \(holds), not the sentinel" : "the clipboard did not change, so Lexicon never wrote to it")
    }
    ok("clipboard restored to the sentinel")
}

func hook(_ arguments: [String]) async throws {
    var timeout = Duration.seconds(10)
    let command: TestHookCommand
    if arguments.first == "insert" {
        var words = arguments.dropFirst()
        var delay = 0.0
        if words.first == "--delay" {
            guard let seconds = words.dropFirst().first.flatMap(Double.init), seconds >= 0 else { fail(usage, code: 64) }
            delay = seconds
            words = words.dropFirst(2)
        }
        guard !words.isEmpty else { fail(usage, code: 64) }
        command = .insert(text: words.joined(separator: " "), delay: delay)
        // The app waits `delay` seconds for a click into the field before it pastes.
        timeout += .seconds(delay)
    } else {
        command = switch (arguments.first, arguments.dropFirst().first, arguments.count) {
        case ("status", _, 1): .status
        case ("dictate", let wav?, 2): .dictate(wav: URL(filePath: wav).standardizedFileURL.path)
        case ("indicator", let state?, 2): .indicator(state: state)
        default: fail(usage, code: 64)
        }
    }
    switch try await DevApp.hooks.send(command, timeout: timeout) {
    case .status(let status):
        try printJSON(status)
    case .inserted(let insertion):
        try printJSON(insertion)
    case .failed(let reason):
        fail("FAIL  \(reason)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "check": try await check()
    case "paste-check": try await pasteCheck()
    case "hook": try await hook(Array(arguments.dropFirst()))
    case TargetField.mode: TargetField.serve(text: arguments.dropFirst().first ?? "", focused: arguments.dropFirst(2).first == "focused")
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
