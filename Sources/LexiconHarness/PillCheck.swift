#if DEBUG
import AppKit
import LexiconDomain
import TestHooks

/// `pill [--shots <dir>]`: shows each indicator state on the running Lexicon Dev
/// and checks what Jake would see: the pill, the menu bar icon, and the focus,
/// which the pill must leave alone. Then plays each sound and times it. With
/// `--shots`, saves a picture of the pill and of the menu bar icon for each state
/// the pill shows.
@MainActor
func pill(_ arguments: [String]) async throws {
    let shots = shotsFolder(arguments)
    if let shots { try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }

    try AX.start()
    let app = try await DevApp.launch()
    let item = try await app.statusItem()

    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
        throw HarnessError("no app is frontmost: click into a text field in another app first")
    }
    guard pid != app.status.pid else {
        throw HarnessError("Lexicon Dev is frontmost: click into a text field in another app first")
    }
    let focus = Focus(pid: pid)

    for expectation in indicatorExpectations {
        guard let state = indicatorState(named: expectation.name) else {
            throw HarnessError("\(expectation.name) is not an indicator state")
        }
        let asked = ContinuousClock.now
        let reply = try await DevApp.hooks.send(.indicator(state), timeout: .seconds(5))
        guard case .done = reply else { throw unexpected(reply, to: "indicator \(expectation.name)") }

        // Landed clears itself from 150 ms (gone by about 0.45 s), so it is read at once and again at 700 ms.
        try await Task.sleep(for: state == .landed ? .milliseconds(20) : .milliseconds(300))
        try checkPill(expectation, state: state, app: app)
        try checkMenuBar(expectation, item: item)
        try checkFocus(expectation, app: app, focus: focus)
        if let shots, state != .hidden {
            saveShots(in: shots, state: expectation.name, app: app, item: item)
        }
        if state == .landed {
            try await Task.sleep(until: asked.advanced(by: .milliseconds(700)), clock: .continuous)
            guard indicatorWindow(app) == nil else { throw HarnessError("landed: the pill is still on screen at 700 ms") }
            ok("landed: pill is gone by 700 ms")
        }
    }

    for (index, cue) in SoundCue.allCases.enumerated() {
        // Back to back, two cues would overlap.
        if index > 0 { try await Task.sleep(for: .milliseconds(600)) }
        let reply = try await DevApp.hooks.send(.sound(cue), timeout: .seconds(5))
        guard case .soundPlayed(let latency) = reply else { throw unexpected(reply, to: "sound \(cue.rawValue)") }
        guard latency < .milliseconds(20) else {
            throw HarnessError("sound \(cue.rawValue) took \(milliseconds(latency)) ms to reach the output (the limit is 20 ms)")
        }
        ok("sound \(cue.rawValue) reached the output in \(milliseconds(latency)) ms")
    }

    let reply = try await DevApp.hooks.send(.indicator(.hidden), timeout: .seconds(5))
    guard case .done = reply else { throw unexpected(reply, to: "indicator hidden") }
}

/// `pill` takes nothing, or `--shots <dir>`. A relative folder is relative to the
/// repo root, where scripts/harness.sh runs the harness.
func shotsFolder(_ arguments: [String]) -> URL? {
    if arguments.isEmpty { return nil }
    guard arguments.count == 2, arguments[0] == "--shots" else { fail(usage, code: 64) }
    return URL(filePath: arguments[1]).standardizedFileURL
}

/// The error for a reply other than the one asked for. `.failed` carries the app's reason.
func unexpected(_ reply: TestHookReply, to request: String) -> HarnessError {
    if case .failed(let reason) = reply { return HarnessError("\(request): \(reason)") }
    return HarnessError("\(request): unexpected reply \(reply)")
}

/// The pill is on screen exactly when the state is not hidden. When the state
/// has text, the text is there too, and the pill never takes main or focus.
@MainActor
func checkPill(_ expectation: IndicatorExpectation, state: IndicatorState, app: DevApp) throws {
    let name = expectation.name
    guard let window = indicatorWindow(app) else {
        guard state == .hidden else {
            throw HarnessError("\(name): no pill on screen (no window with identifier \(AccessibilityID.indicator))")
        }
        ok("\(name): pill is off screen")
        return
    }
    guard state != .hidden else { throw HarnessError("\(name): the pill is still on screen") }
    ok("\(name): pill is on screen")

    if let text = expectation.pillText {
        let texts = AX.staticTexts(window)
        guard texts.contains(where: { $0.contains(text) }) else {
            throw HarnessError("\(name): the pill reads \(texts), not \(text.debugDescription)")
        }
        ok("\(name): pill says \(text.debugDescription)")
    }

    // The pill must never take main or focus. A window that exposes neither passes.
    let taken = [kAXMainAttribute, kAXFocusedAttribute].filter { (AX.value(window, $0) as? Bool) == true }
    guard taken.isEmpty else {
        throw HarnessError("\(name): the pill is \(taken.joined(separator: " and ")), but it must never take focus")
    }
    ok("\(name): pill is not main or focused")
}

@MainActor
func checkMenuBar(_ expectation: IndicatorExpectation, item: AXUIElement) throws {
    // The label is the AXDescription, with the AXTitle as the fallback.
    let label = AX.string(item, kAXDescriptionAttribute) ?? AX.string(item, kAXTitleAttribute)
    guard label == expectation.statusLabel else {
        throw HarnessError("\(expectation.name): the menu bar icon reads \(label?.debugDescription ?? "nothing"), not \(expectation.statusLabel.debugDescription)")
    }
    ok("\(expectation.name): menu bar icon reads \(expectation.statusLabel.debugDescription)")
}

/// The focus the pill must leave alone: the app that was frontmost before the pill
/// showed, and its focused element and window. Either element may be nil, as on
/// the desktop with no focused window.
struct Focus {
    let pid: pid_t
    let element: AXUIElement?
    let window: AXUIElement?

    /// Read per app: the system-wide focused-element query fails with some apps frontmost.
    init(pid: pid_t) {
        self.pid = pid
        let app = AX.app(pid)
        element = AX.element(app, kAXFocusedUIElementAttribute)
        window = AX.element(app, kAXFocusedWindowAttribute)
    }
}

@MainActor
func checkFocus(_ expectation: IndicatorExpectation, app: DevApp, focus: Focus) throws {
    let name = expectation.name
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard frontmost == focus.pid, frontmost != app.status.pid else {
        throw HarnessError("\(name): focus moved: pid \(focus.pid) was frontmost, now it is pid \(frontmost.map { "\($0)" } ?? "none")")
    }
    ok("\(name): frontmost app is still pid \(focus.pid), not Lexicon Dev")

    let now = Focus(pid: focus.pid)
    guard sameElement(now.element, focus.element), sameElement(now.window, focus.window) else {
        throw HarnessError("\(name): pid \(focus.pid) changed its focused element or window")
    }
    ok("\(name): its focused element and window are unchanged")
}

/// CFEqual for optionals: two missing elements count as the same.
func sameElement(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case let (a?, b?): CFEqual(a, b)
    default: false
    }
}

/// The pill, found by its identifier among the app's windows.
@MainActor
func indicatorWindow(_ app: DevApp) -> AXUIElement? {
    AX.find(AccessibilityID.indicator, in: AX.elements(app.element, kAXWindowsAttribute))
}

/// Saves the pill and the menu bar icon as they look in `state`. A picture that
/// cannot be taken is a warning: the checks have already passed.
@MainActor
func saveShots(in folder: URL, state: String, app: DevApp, item: AXUIElement) {
    if let number = pillWindowNumber(pid: app.status.pid) {
        capture(["-x", "-o", "-l\(number)", folder.appending(path: "\(state)-pill.png").path], label: "\(state) pill")
    } else {
        print("warn  \(state) pill: no window of Lexicon Dev is on screen")
    }

    guard let frame = AX.frame(item) else {
        print("warn  \(state) menu bar icon: no position to crop it to")
        return
    }
    let padded = frame.insetBy(dx: -4, dy: -4)
    let rect = [padded.minX.rounded(.down), padded.minY.rounded(.down), padded.width.rounded(.up), padded.height.rounded(.up)]
        .map { "\(Int($0))" }
        .joined(separator: ",")
    capture(["-x", "-R\(rect)", folder.appending(path: "\(state)-menubar.png").path], label: "\(state) menu bar icon")
}

/// `screencapture` through `run`, with a failure as a warning line.
func capture(_ arguments: [String], label: String) {
    do {
        try run("/usr/sbin/screencapture", arguments)
    } catch {
        print("warn  \(label) not saved: \(error)")
    }
}

/// The window number of the pill: the lowest window Lexicon Dev has on screen.
/// The menu bar icon sits at the top, so the pill has the largest Y.
func pillWindowNumber(pid: pid_t) -> Int? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let owned: [(number: Int, y: CGFloat)] = windows.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let number = window[kCGWindowNumber as String] as? Int,
              let bounds = window[kCGWindowBounds as String],
              let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { return nil }
        return (number, rect.minY)
    }
    return owned.max { $0.y < $1.y }?.number
}
#endif
