#if DEBUG
import AppKit
import LexiconDomain

/// `lexicon-harness history [word]`: the History window on the running Lexicon
/// Dev. Opens it from the menu bar `runs` times, timing the History menu item's
/// press to rows on screen as Accessibility sees them (an upper bound on what
/// Jake sees), clicks the newest row and checks the clipboard and "Copied",
/// optionally searches for `word`, then closes the window and compares the
/// app's memory footprint before opening and after closing.
///
/// Jake's clipboard is put back as it was. Dictation text is never printed:
/// the dev data folder may hold whatever another builder dictated.
@MainActor
enum HistoryCheck {
    static func run(search word: String?, runs: Int = 20) async throws {
        try AX.start()
        let app = try await DevApp.launch()
        let pid = app.status.pid
        let before = try footprint(pid)

        var times: [Duration] = []
        for _ in 0..<runs {
            let (window, _, elapsed) = try await open(app)
            times.append(elapsed)
            try await close(window, app)
        }
        let sorted = times.sorted()
        func ms(_ duration: Duration) -> Int { Int((duration / .milliseconds(1)).rounded()) }
        ok("History opened \(runs) times: menu item to first rows p50 \(ms(sorted[runs / 2])) ms, p95 \(ms(sorted[Int((Double(runs) * 0.95).rounded(.up)) - 1])) ms")

        let (window, table, _) = try await open(app)
        let open = try footprint(pid)
        try await copyNewest(table)
        if let word { try await search(word, window: window, table: table) }
        try await close(window, app)
        try await Task.sleep(for: .seconds(2))
        let after = try footprint(pid)
        ok("footprint: \(mib(before)) before opening, \(mib(open)) open, \(mib(after)) after closing")
    }

    /// Presses the menu bar item's History entry and waits for rows on screen.
    static func open(_ app: DevApp) async throws -> (window: AXUIElement, table: AXUIElement, elapsed: Duration) {
        let item = try await app.statusItem()
        // Opening a menu tracks it modally, so the press may not reply before the timeout.
        let opened = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard opened == .success || opened == .cannotComplete else { throw HarnessError("opening the menu failed (AXError \(opened.rawValue))") }
        let entry = try await poll("the History menu item") {
            AX.elements(item, kAXChildrenAttribute).lazy
                .flatMap { AX.elements($0, kAXChildrenAttribute) }
                .first { AX.string($0, kAXTitleAttribute) == "History" }
        }
        let clock = ContinuousClock()
        let pressed = clock.now
        try press(entry)
        let found = try await poll("History rows on screen", every: .milliseconds(2)) { () -> (AXUIElement, AXUIElement)? in
            guard let window = AX.find(AccessibilityID.historyWindow, in: AX.elements(app.element, kAXWindowsAttribute), depth: 0),
                  let table = AX.find(AccessibilityID.historyTable, in: [window]),
                  !AX.elements(table, kAXVisibleRowsAttribute).isEmpty else { return nil }
            return (window, table)
        }
        return (found.0, found.1, clock.now - pressed)
    }

    /// Clicks the newest Dictation (the row under the first day header) and
    /// checks that its text is on the clipboard and that it says "Copied".
    static func copyNewest(_ table: AXUIElement) async throws {
        let rows = AX.elements(table, kAXVisibleRowsAttribute)
        guard rows.count > 1 else { throw HarnessError("History shows no Dictation to copy (seed the dev data folder first)") }
        let row = rows[1]
        let text = texts(in: row).max { $0.count < $1.count } ?? ""
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            })
        }
        try click(row)
        _ = try await poll("\"Copied\" on the clicked row") { texts(in: row).contains("Copied") ? true : nil }
        guard pasteboard.string(forType: .string) == text, !text.isEmpty else {
            throw HarnessError("the clipboard does not hold the clicked row's text")
        }
        ok("clicking the newest row put its \(text.count) characters on the clipboard and showed \"Copied\"")
    }

    static func search(_ word: String, window: AXUIElement, table: AXUIElement) async throws {
        guard let field = AX.find(AccessibilityID.historySearch, in: [window]) else {
            throw HarnessError("no search field with identifier \(AccessibilityID.historySearch)")
        }
        let all = AX.elements(table, kAXRowsAttribute).count
        try AX.set(field, kAXValueAttribute, word as CFString)
        AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        let rows = try await poll("search results") { () -> [AXUIElement]? in
            let rows = AX.elements(table, kAXRowsAttribute)
            return rows.count < all ? rows : nil
        }
        let visible = AX.elements(table, kAXVisibleRowsAttribute)
        // Day headers have one short text; every Dictation row must contain the word.
        let misses = visible.filter { row in
            let texts = texts(in: row)
            return texts.count > 1 && !texts.contains { $0.localizedCaseInsensitiveContains(word) }
        }
        guard misses.isEmpty else { throw HarnessError("\(misses.count) visible rows do not contain the search word") }
        ok("search for \(word.debugDescription): \(rows.count) of \(all) rows, every visible Dictation matches")
    }

    static func close(_ window: AXUIElement, _ app: DevApp) async throws {
        guard let button = AX.element(window, kAXCloseButtonAttribute) else { throw HarnessError("the History window has no close button") }
        try press(button)
        _ = try await poll("the History window to close") {
            AX.find(AccessibilityID.historyWindow, in: AX.elements(app.element, kAXWindowsAttribute), depth: 0) == nil ? true : nil
        }
    }

    /// Every static text's value under `element`.
    static func texts(in element: AXUIElement, depth: Int = 4) -> [String] {
        AX.elements(element, kAXChildrenAttribute).flatMap { child -> [String] in
            let own = AX.string(child, kAXRoleAttribute) == kAXStaticTextRole ? [AX.string(child, kAXValueAttribute) ?? ""] : []
            return own + (depth > 0 ? texts(in: child, depth: depth - 1) : [])
        }
    }

    static func press(_ element: AXUIElement) throws {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw HarnessError("press failed (AXError \(result.rawValue))") }
    }

    /// A real mouse click at the element's center: a table row has no press action.
    static func click(_ element: AXUIElement) throws {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let position = AX.value(element, kAXPositionAttribute), let extent = AX.value(element, kAXSizeAttribute),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),  // AXPosition is always an AXValue
              AXValueGetValue(extent as! AXValue, .cgSize, &size) else { throw HarnessError("cannot find the row on screen") }
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    static func poll<T>(_ what: String, every interval: Duration = .milliseconds(20), within limit: Duration = .seconds(5),
                        _ probe: () -> T?) async throws -> T {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let found = probe() { return found }
            try await Task.sleep(for: interval)
        }
        throw HarnessError("timed out waiting for \(what)")
    }

    /// The process's physical footprint in bytes, from `footprint`.
    static func footprint(_ pid: pid_t) throws -> Int {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/footprint")
        process.arguments = ["-f", "bytes", String(pid)]
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let match = text.firstMatch(of: /Footprint: (\d+) B/), let bytes = Int(match.1) else {
            throw HarnessError("cannot read the footprint of pid \(pid)")
        }
        return bytes
    }

    static func mib(_ bytes: Int) -> String { String(format: "%.1f MiB", Double(bytes) / 1_048_576) }
}
#endif
