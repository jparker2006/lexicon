#if DEBUG
import AppKit

/// The known text field Lexicon types into: a small window with one text area,
/// run by this same binary as a child process (`lexicon-harness target-field
/// <text>`). Background only, so it never becomes the active app: a target that
/// activated at launch (as a regular or even an accessory app run this way
/// does) takes whatever Jake is typing. A paste check will need a deliberate
/// way to give it focus.
@MainActor
final class TargetField {
    static let mode = "target-field"
    static let identifier = "lexicon.harness.targetField"

    let process: Process
    let app: AXUIElement
    let field: AXUIElement

    private init(process: Process, app: AXUIElement, field: AXUIElement) {
        self.process = process
        self.app = app
        self.field = field
    }

    /// Starts the window with `text` already in the field.
    static func open(text: String) async throws -> TargetField {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = [mode, text]
        try process.run()
        let app = AX.app(process.processIdentifier)
        for _ in 0..<100 {
            if let field = AX.find(identifier, in: AX.elements(app, kAXWindowsAttribute)) {
                return TargetField(process: process, app: app, field: field)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        throw HarnessError("the target field did not appear within 5 s")
    }

    func text() throws -> String {
        guard let text = AX.string(field, kAXValueAttribute) else { throw HarnessError("cannot read the target field") }
        return text
    }

    func clear() throws {
        try AX.set(field, kAXValueAttribute, "" as CFString)
    }

    /// Quits the child this harness started (by its own pid, never by name).
    func close() {
        process.terminate()
        process.waitUntilExit()
    }

    /// The child: show the window and run until terminated, or until the
    /// harness that started it exits, so a crashed harness leaves nothing behind.
    static func serve(text: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)  // see the type comment: never activate
        let parentGone = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
        parentGone.setEventHandler { exit(0) }
        parentGone.resume()

        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.string = text
        textView.setAccessibilityIdentifier(identifier)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Lexicon Harness Target"
        window.contentView = scroll
        window.initialFirstResponder = textView
        window.center()
        window.orderFrontRegardless()
        withExtendedLifetime(parentGone) { app.run() }
        exit(0)
    }
}
#endif
