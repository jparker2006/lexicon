#if DEBUG
import AppKit
import LexiconDomain
import TestHooks

/// `lexicon-harness check`: launch Lexicon Dev with test hooks, find its status item,
/// list its windows, open the target field, read it and clear it.
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
    guard try target.text() == text else { throw HarnessError("the target field reads \(Fingerprint(try target.text())), not \(Fingerprint(text))") }
    ok("target field reads the text (\(Fingerprint(text)))")
    try target.clear()
    guard try target.text().isEmpty else { throw HarnessError("the target field still reads \(Fingerprint(try target.text())) after clearing") }
    ok("target field cleared")
}
#endif
