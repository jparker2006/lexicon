#if DEBUG
import AppKit
import LexiconDomain
import TestHooks

/// `lexicon-harness paste-check`: paste a sentence into the target field through the
/// real paste path, then check the field reads it and the clipboard is restored.
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
    try await run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(target.process.processIdentifier)) to true"])
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
    case .status, .capture, .done, .soundPlayed, .dictated, .replaced:
        throw HarnessError("unexpected reply to insert: \(reply)")
    }

    let readDeadline = ContinuousClock.now + .seconds(1)
    while try target.text() != text {
        guard ContinuousClock.now < readDeadline else { throw HarnessError("the target field reads \(Fingerprint(try target.text())), not \(Fingerprint(text))") }
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
#endif
