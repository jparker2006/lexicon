#if DEBUG
import AppKit

/// The known text field Lexicon types into: a small window with one text area,
/// run by this same binary as a child process (`lexicon-harness target-field
/// <text>`). Background by default, so it never becomes the active app: a target
/// that activated at launch (as a regular or even an accessory app run this way
/// does) takes whatever Jake is typing. The focused mode (`<text> focused`) exists
/// for the paste check: it is a regular app that takes keyboard focus on purpose,
/// for the few seconds that check needs it.
@MainActor
final class TargetField {
    static let mode = "target-field"
    static let identifier = "lexicon.harness.targetField"

    let process: Process
    let field: AXUIElement

    private init(process: Process, field: AXUIElement) {
        self.process = process
        self.field = field
    }

    /// Starts the window with `text` already in the field. `focused` starts the
    /// child in the mode that takes keyboard focus (see the type comment).
    static func open(text: String, focused: Bool = false) async throws -> TargetField {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = [mode, text] + (focused ? ["focused"] : [])
        try process.run()
        let app = AX.app(process.processIdentifier)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let field = AX.find(identifier, in: AX.elements(app, kAXWindowsAttribute)) {
                return TargetField(process: process, field: field)
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
    static func serve(text: String, focused: Bool) -> Never {
        let parent = getppid()
        let parentGone = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        parentGone.setEventHandler { exit(0) }
        parentGone.resume()
        // Gone before the watch started: it would never fire.
        if parent == 1 || kill(parent, 0) != 0 { exit(0) }

        let app = NSApplication.shared
        app.setActivationPolicy(focused ? .regular : .prohibited)  // see the type comment: never activate unless focused

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
        if focused {
            app.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
        } else {
            window.orderFrontRegardless()
        }
        withExtendedLifetime(parentGone) { app.run() }
        exit(0)
    }
}
#endif
