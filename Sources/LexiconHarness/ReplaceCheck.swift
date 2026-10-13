#if DEBUG
import AppKit
import TestHooks

/// `lexicon-harness replace-check [--frontmost]`: the Re-speak replace path on a field, through the
/// real insert and replace hooks. By default the harness's own target field. With `--frontmost`, the
/// focused field of the frontmost app, which must read empty first. Nothing sends Return: the hooks
/// paste with Cmd-V, and that is the only key the check causes.
@MainActor
func replaceCheck(frontmost: Bool) async throws {
    try AX.start()
    let app = try await DevApp.launch()
    let status = app.status
    ok("Lexicon Dev \(status.version) answers test hooks (pid \(status.pid), accessibility=\(status.accessibility), microphone=\(status.microphone))")

    // The hooks paste into the focused field of the frontmost app, so that field is the one checked.
    var target: TargetField?
    if !frontmost { target = try await TargetField.open(text: "", focused: true) }
    defer { target?.close() }
    if let target {
        // As paste-check does: System Events brings the target forward, and Cmd-V needs it to have focus.
        try await run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(target.process.processIdentifier)) to true"])
        let focusDeadline = ContinuousClock.now + .seconds(2)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.process.processIdentifier {
            guard ContinuousClock.now < focusDeadline else { throw HarnessError("the target field did not become the frontmost app within 2 s, so Cmd-V would not reach it") }
            try await Task.sleep(for: .milliseconds(50))
        }
        ok("target field is frontmost")
    }
    let field = try target?.field ?? focusedField()

    // A sentinel on the clipboard: after the replaces, Lexicon must have put it back. Whatever Jake
    // had copied is put back when the check ends, never printed.
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

    // Only an empty field: the text the checks read is then the text they put there.
    guard try value(of: field).isEmpty else {
        throw HarnessError("the field reads \(Fingerprint(try value(of: field))), not empty: start a new, empty field, then run this again")
    }
    ok("field is empty")

    let nonce = String(UUID().uuidString.prefix(8))
    let sentence = "alpha beta gamma beta \(nonce)"
    switch try await DevApp.hooks.send(.insert(text: sentence, delay: 0), timeout: .seconds(10)) {
    case .inserted(let insertion):
        ok("insert reply: \(insertion.outcome), target \(insertion.targetMicros) us")
        guard insertion.outcome == "inserted" else { throw HarnessError("Lexicon did not insert: \(insertion.outcome)") }
    case .failed(let reason):
        throw HarnessError(reason)
    case .status, .capture, .done, .soundPlayed, .dictated, .replaced:
        throw HarnessError("unexpected reply to insert")
    }
    try await checkField(sentence, in: field)

    // The second "beta" only: the first one stays, so the check shows which occurrence was replaced.
    let first = try replacement(try await DevApp.hooks.send(.replace(word: "beta", occurrence: 2, with: "Supabase", delay: 0), timeout: .seconds(10)))
    ok("replace beta 2 with Supabase: \(first.outcome), read \(first.readMicros) us, replace \(first.replaceMicros) us, field \(first.fieldLengthBefore) UTF-16")
    guard first.outcome == "replaced" else { throw HarnessError("Lexicon did not replace: \(first.outcome)") }
    let supabase = "alpha beta gamma Supabase \(nonce)"
    try await checkField(supabase, in: field)

    // The selection path: a selection made through Accessibility is what a Re-speak replaces.
    let gamma = (supabase as NSString).range(of: "gamma")
    try select(gamma, in: field)
    // Chromium applies a selection a moment after it is set.
    let selectDeadline = ContinuousClock.now + .milliseconds(500)
    while AX.string(field, kAXSelectedTextAttribute) != "gamma" {
        guard ContinuousClock.now < selectDeadline else { throw HarnessError("the field did not select gamma within 500 ms") }
        try await Task.sleep(for: .milliseconds(20))
    }
    ok("selected gamma")

    let kotlin = try replacement(try await DevApp.hooks.send(.replaceSelection(with: "Kotlin", delay: 0), timeout: .seconds(10)))
    ok("replace selection with Kotlin: \(kotlin.outcome), read \(kotlin.readMicros) us, replace \(kotlin.replaceMicros) us, field \(kotlin.fieldLengthBefore) UTF-16")
    guard kotlin.outcome == "replaced" else { throw HarnessError("Lexicon did not replace the selection: \(kotlin.outcome)") }
    try await checkField("alpha beta Kotlin Supabase \(nonce)", in: field)

    // Lexicon restores the clipboard 200 ms after the paste is read; 1 s leaves room on a slow machine.
    try await Task.sleep(for: .seconds(1))
    let held = pasteboard.string(forType: .string)
    let wrote = pasteboard.changeCount != count
    // Says what the clipboard holds without printing it: it can be text Jake copied himself.
    let holds = switch held {
    case sentinel?: "the sentinel"
    case let other?: "\(other.count) characters"
    case nil: "no string"
    }
    guard wrote, held == sentinel else {
        throw HarnessError(wrote ? "the clipboard holds \(holds), not the sentinel" : "the clipboard did not change, so Lexicon never wrote to it")
    }
    ok("clipboard restored to the sentinel")
    print("PASS  replace-check: both replaces landed in the field and the clipboard is restored")
}

/// The focused field of the frontmost app, read per app: the system-wide
/// focused-element query fails with some apps frontmost (Claude desktop).
@MainActor
private func focusedField() throws -> AXUIElement {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
          let field = AX.element(AX.app(pid), kAXFocusedUIElementAttribute) else {
        throw HarnessError("no focused field: click into an empty field in the frontmost app, then run this again")
    }
    return field
}

/// The field's text through Accessibility. Never printed: callers print a Fingerprint.
private func value(of field: AXUIElement) throws -> String {
    guard let text = AX.string(field, kAXValueAttribute) else { throw HarnessError("cannot read the field through Accessibility") }
    return text
}

/// Reads the field for up to 1 s until it reads `expected`, then checks it. Prints fingerprints only.
/// On the main actor with the field: an AXUIElement is not Sendable, so it never crosses to another task.
@MainActor
private func checkField(_ expected: String, in field: AXUIElement) async throws {
    let deadline = ContinuousClock.now + .seconds(1)
    var text = try value(of: field)
    while text != expected, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
        text = try value(of: field)
    }
    guard text == expected else { throw HarnessError("the field reads \(Fingerprint(text)), not \(Fingerprint(expected))") }
    ok("field reads \(Fingerprint(expected))")
}

/// The reply to a replace hook: what it did, or why it refused.
private func replacement(_ reply: TestHookReply) throws -> TestHookReplacement {
    switch reply {
    case .replaced(let result): return result
    case .failed(let reason): throw HarnessError(reason)
    case .status, .capture, .done, .soundPlayed, .inserted, .dictated: throw HarnessError("unexpected reply to replace: \(reply)")
    }
}

/// Selects `range` in the field through Accessibility, as Jake's own selection would be.
private func select(_ range: NSRange, in field: AXUIElement) throws {
    var cfRange = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &cfRange) else { throw HarnessError("cannot make a selection range") }
    try AX.set(field, kAXSelectedTextRangeAttribute, value)
}
#endif
