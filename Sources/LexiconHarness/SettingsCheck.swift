#if DEBUG
import AppKit
import Foundation
import LexiconDomain
import TestHooks

/// The Settings check has two modes: a closed, fixed-value Dev fixture and a
/// no-hook timing attachment to an already running release Dev app.
@MainActor
enum SettingsCheck {
    private static let usage = """
        usage: lexicon-harness settings [inspect | --release --surface settings|history --head <SHA> --out <file> --runs <n>]

        With no options, Settings drives the fixed .jev fixture through Dev's
        test hooks. After a separate relaunch, `inspect` checks the blank form
        without editing it.
        Release mode attaches to the running Lexicon Dev, opens the surface from
        its menu, and saves the app's own open-to-drawn time for one first show
        followed by <n> repeated shows, with the menu-to-window time beside it.
        """

    private static let fixtureKeyOne = "lexicon-373-fixture-first-5f8a"
    private static let fixtureKeyTwo = "lexicon-373-fixture-replacement-93c1"
    private static let syntheticCredential = CredentialID.jev

    private enum Surface: String {
        case settings
        case history

        var menuIdentifier: String? {
            switch self {
            case .settings: AccessibilityID.settingsMenu
            case .history: nil
            }
        }

        var menuTitle: String {
            switch self {
            case .settings: "Settings…"
            case .history: "History"
            }
        }

        var windowIdentifier: String {
            switch self {
            case .settings: AccessibilityID.settingsWindow
            case .history: AccessibilityID.historyWindow
            }
        }

        var receiptName: String {
            switch self {
            case .settings: "Settings (Keys only)"
            case .history: "main History control"
            }
        }

        /// The app's own line for each new window, timed from being asked to open to drawn.
        var logCategory: String {
            switch self {
            case .settings: "Settings"
            case .history: "History"
            }
        }

        var drawnLine: Regex<(Substring, Substring)> {
            switch self {
            case .settings: /Settings window: usable grid drawn (\d+) ms after open/
            case .history: /History window: first rows drawn (\d+) ms after open/
            }
        }
    }

    private struct ReleaseApp {
        let application: NSRunningApplication
        let bundlePath: String
        let reviewedHead: String
        let sourceHead: String
        let buildHead: String

        var element: AXUIElement { AX.app(application.processIdentifier) }
        var pid: pid_t { application.processIdentifier }
    }

    private struct GitResult {
        let status: Int32
        let output: String
    }

    static func run(_ arguments: [String]) async throws {
        if arguments.isEmpty {
            try await runFixture()
            return
        }
        if arguments == ["inspect"] {
            try await inspectForm()
            return
        }
        try await runRelease(arguments)
    }

    private static func inspectForm() async throws {
        try AX.start()
        let app = try await DevApp.launch()
        let application = AX.app(app.status.pid)
        let initial = try await inspectFixture()
        try requireObservation(initial, phase: .idle, pid: app.status.pid, fieldsEmpty: true)

        let window = try await openSettings(app: application)
        try requireSettingsForm(window)
        try requireSameProcess(application, pid: app.status.pid)
        let reopened = try await inspectFixture()
        try requireObservation(reopened, phase: .idle, pid: app.status.pid, fieldsEmpty: true)
        try await close(window, identifier: AccessibilityID.settingsWindow, app: application)
        ok("reopened Settings has the canonical Keys form and empty secure fields in pid \(app.status.pid)")
    }

    private static func runRelease(_ arguments: [String]) async throws {
        let options = try parseReleaseOptions(arguments)
        let app = try await releaseApp(expectedHead: options.head)
        try AX.start()

        guard windowCount(options.surface, app: app.element) == 0 else {
            throw HarnessError("close the existing \(options.surface.receiptName) window before measuring")
        }

        // A second before now: `log show` starts on whole seconds, and the app has
        // shown no such window since this fresh launch.
        let since = Date().addingTimeInterval(-1)
        var menuToWindow: [Int] = []
        for _ in 0...options.runs {
            let menuItem = try await menuItem(for: options.surface, app: app.element)
            let clock = ContinuousClock()
            let start = clock.now
            try press(menuItem)
            _ = try await usableWindow(options.surface, app: app.element, every: .milliseconds(2))
            menuToWindow.append(ceilMilliseconds(clock.now - start))
            guard windowCount(options.surface, app: app.element) == 1 else {
                throw HarnessError("expected one \(options.surface.receiptName) window after its menu action")
            }
            try await closeWindow(options.surface, app: app)
        }
        let samples = try await drawnTimes(options.surface, pid: app.pid, since: since, count: menuToWindow.count)

        try writeReceipt(options: options, app: app, samples: samples, menuToWindow: menuToWindow)
        let first = samples[0]
        ok("\(options.surface.receiptName): first show \(first) ms open to drawn (\(menuToWindow[0]) ms menu to window), \(options.runs) repeated shows, samples saved to \(options.out.path)")
        ok("reviewed head \(app.reviewedHead), source head \(app.sourceHead), build head \(app.buildHead), pid \(app.pid)")
    }

    private static func parseReleaseOptions(_ arguments: [String]) throws -> (surface: Surface, head: String, out: URL, runs: Int) {
        var values: [String: String] = [:]
        var index = 0
        guard arguments.first == "--release" else { throw HarnessError(usage) }
        index += 1
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--surface", "--head", "--out", "--runs"].contains(flag),
                  index + 1 < arguments.count,
                  values[flag] == nil else { throw HarnessError(usage) }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard values.count == 4,
              let surfaceName = values["--surface"], let surface = Surface(rawValue: surfaceName),
              let head = values["--head"], isSHA(head),
              let output = values["--out"], !output.isEmpty,
              let runText = values["--runs"], let runs = Int(runText), (0...100).contains(runs) else {
            throw HarnessError(usage)
        }
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let outputURL = URL(filePath: output, relativeTo: currentDirectory).standardizedFileURL
        return (surface, head.lowercased(), outputURL, runs)
    }

    private static func releaseApp(expectedHead: String) async throws -> ReleaseApp {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.devBundleID)
        guard running.count == 1, let application = running.first, !application.isTerminated,
              let bundleURL = application.bundleURL else {
            throw HarnessError("release Settings check needs one already running Lexicon Dev app")
        }
        let actualPath = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let expectedPath = DevApp.installed.standardizedFileURL.resolvingSymlinksInPath()
        guard actualPath == expectedPath else {
            throw HarnessError("running Lexicon Dev is not at \(expectedPath.path)")
        }
        let binary = actualPath.appending(path: "Contents/MacOS/Lexicon")
        let isDebug = try Data(contentsOf: binary).range(of: Data("TestHook".utf8)) != nil
        guard !isDebug else {
            throw HarnessError("the running Lexicon Dev is a debug build; settings release checks require a release build")
        }
        guard let info = Bundle(url: bundleURL)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == AppPaths.devBundleID,
              let recordedHead = info["LexiconCommit"] as? String,
              isSHA(recordedHead) else {
            throw HarnessError("running Lexicon Dev has no valid bundle identity and build head")
        }

        let sourceHead = try await git(["rev-parse", "HEAD"])
        try await requireCleanSource()
        let reviewedHead = try await git(["rev-parse", "--verify", "\(expectedHead)^{commit}"])
        let buildHead = recordedHead.lowercased()
        guard sourceHead == reviewedHead,
              buildHead == String(reviewedHead.prefix(buildHead.count)),
              buildHead.count >= 7 else {
            throw HarnessError("running build, source checkout and reviewed head do not agree")
        }

        return ReleaseApp(application: application, bundlePath: actualPath.path,
                          reviewedHead: reviewedHead, sourceHead: sourceHead, buildHead: buildHead)
    }

    @MainActor
    private final class GitCommand {
        private let process: Process
        private let output: Pipe
        private let continuation: CheckedContinuation<GitResult, any Error>
        private var timedOut = false
        private var completed = false

        init(process: Process, output: Pipe, continuation: CheckedContinuation<GitResult, any Error>) {
            self.process = process
            self.output = output
            self.continuation = continuation
        }

        func finish(status: Int32) {
            guard !completed else { return }
            completed = true
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard !timedOut, let value = String(data: data, encoding: .utf8) else {
                continuation.resume(throwing: HarnessError("cannot verify the source head with git"))
                return
            }
            continuation.resume(returning: GitResult(status: status, output: value.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        func failToStart() {
            guard !completed else { return }
            completed = true
            continuation.resume(throwing: HarnessError("cannot verify the source head with git"))
        }

        func timeOut() {
            guard !completed else { return }
            timedOut = true
            if process.isRunning { process.terminate() }
        }
    }

    private static func gitResult(_ arguments: [String]) async throws -> GitResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitResult, any Error>) in
            let command = GitCommand(process: process, output: output, continuation: continuation)
            process.terminationHandler = { [command] terminated in
                let status = terminated.terminationStatus
                Task { @MainActor in command.finish(status: status) }
            }
            do {
                try process.run()
            } catch {
                command.failToStart()
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                command.timeOut()
            }
        }
    }

    private static func git(_ arguments: [String]) async throws -> String {
        let result = try await gitResult(arguments)
        guard result.status == 0, result.output.count == 40,
              result.output.allSatisfy({ $0.isHexDigit }) else {
            throw HarnessError("cannot verify the source head with git")
        }
        return result.output.lowercased()
    }

    private static func requireCleanSource() async throws {
        let result = try await gitResult(["status", "--porcelain", "--untracked-files=all", "--",
                                          "Sources", "Package.swift", "Package.resolved", "scripts/app"])
        guard result.status == 0 else { throw HarnessError("cannot verify the source checkout with git") }
        guard result.output.isEmpty else {
            throw HarnessError("the source checkout has uncommitted app or build changes")
        }
    }

    private static func ceilMilliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return Int(ceil(milliseconds))
    }

    private static func isSHA(_ value: String) -> Bool {
        (7...40).contains(value.count) && value.allSatisfy({ $0.isHexDigit })
    }

    private static func runFixture() async throws {
        try AX.start()
        let app = try await DevApp.launch()
        let application = AX.app(app.status.pid)
        var fixtureMayBeActive = false
        var lastPhase = "idle"

        do {
            let initial = try await inspectFixture()
            lastPhase = initial.phase.rawValue
            try requireObservation(initial, phase: .idle, pid: app.status.pid, fieldsEmpty: true)

            var window = try await openSettings(app: application)
            try requireSettingsForm(window)
            try requireSameProcess(application, pid: app.status.pid)
            let opened = try await inspectFixture()
            lastPhase = opened.phase.rawValue
            try requireObservation(opened, phase: .idle, pid: app.status.pid, fieldsEmpty: true)

            let reused = try await openSettings(app: application)
            try requireSameSingleWindow(reused, app: application)
            window = reused

            try await close(window, identifier: AccessibilityID.settingsWindow, app: application)
            let closed = try await inspectFixture()
            lastPhase = closed.phase.rawValue
            try requireObservation(closed, phase: .idle, pid: app.status.pid, fieldsEmpty: true)

            window = try await openSettings(app: application)
            try requireSettingsForm(window)
            try requireSameProcess(application, pid: app.status.pid)
            let reopened = try await inspectFixture()
            lastPhase = reopened.phase.rawValue
            try requireObservation(reopened, phase: .idle, pid: app.status.pid, fieldsEmpty: true)

            fixtureMayBeActive = true
            let begun = try await sendFixture(.settingsFixtureBegin)
            lastPhase = begun.phase.rawValue
            guard begun.phase == .reserved, begun.outcome == .ok, begun.item == .none,
                  begun.pid == app.status.pid, begun.fieldsAreEmpty else {
                throw HarnessError("fixture begin was unavailable; no item was changed")
            }

            try await saveSynthetic(fixtureKeyOne, in: window, app: application, pid: app.status.pid, label: "first Save")
            let owned = try await waitForFixture(phase: .owned, lastPhase: lastPhase)
            lastPhase = owned.phase.rawValue
            try requireObservation(owned, phase: .owned, pid: app.status.pid, fieldsEmpty: true,
                                  outcome: .ok, cache: .available, item: .present)

            try await saveSynthetic(fixtureKeyTwo, in: window, app: application, pid: app.status.pid,
                                    label: "replacement Save")
            let replaced = try await waitForFixture(phase: .owned, lastPhase: lastPhase)
            lastPhase = replaced.phase.rawValue
            try requireObservation(replaced, phase: .owned, pid: app.status.pid, fieldsEmpty: true,
                                  outcome: .ok, cache: .available, item: .present)

            let remove = try element(AccessibilityID.settingsRemove(syntheticCredential), in: window)
            try press(remove)
            try await waitForStatus("Missing", for: syntheticCredential, in: window)
            let removed = try await waitForFixture(phase: .removed, lastPhase: lastPhase)
            lastPhase = removed.phase.rawValue
            try requireObservation(removed, phase: .removed, pid: app.status.pid, fieldsEmpty: true,
                                  outcome: .ok, cache: .missing, item: .some(.none))

            let ended = try await sendFixture(.settingsFixtureEnd)
            lastPhase = ended.phase.rawValue
            try requireObservation(ended, phase: .idle, pid: app.status.pid, fieldsEmpty: true,
                                  outcome: .ok, item: .some(.none))
            fixtureMayBeActive = false

            try await close(window, identifier: AccessibilityID.settingsWindow, app: application)
            window = try await openSettings(app: application)
            try requireSettingsForm(window)
            try requireSameProcess(application, pid: app.status.pid)
            let final = try await inspectFixture()
            try requireObservation(final, phase: .idle, pid: app.status.pid, fieldsEmpty: true)
            try await close(window, identifier: AccessibilityID.settingsWindow, app: application)
            ok("Settings fixture saved, replaced and removed the fixed .jev item; only owned-item metadata and empty-field state were observed")
        } catch {
            if fixtureMayBeActive {
                throw HarnessError("Settings fixture unavailable/unrun after phase \(lastPhase); its lease is retained. Inspect before continuing. \(error)")
            }
            throw error
        }
    }

    private static func openSettings(app: AXUIElement) async throws -> AXUIElement {
        try await open(Surface.settings, app: app)
    }

    private static func open(_ surface: Surface, app: AXUIElement) async throws -> AXUIElement {
        let menu = try await menuItem(for: surface, app: app)
        try press(menu)
        return try await usableWindow(surface, app: app)
    }

    private static func menuItem(for surface: Surface, app: AXUIElement) async throws -> AXUIElement {
        let item = try await HistoryCheck.poll("Lexicon Dev's menu bar item") { () -> AXUIElement? in
            guard let extras = AX.element(app, "AXExtrasMenuBar") else { return nil }
            return AX.find(AccessibilityID.statusItem, in: [extras])
        }
        for _ in 0..<3 {
            let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
            guard result == .success || result == .cannotComplete else {
                throw HarnessError("opening the menu failed (AXError \(result.rawValue))")
            }
            if let entry = try? await HistoryCheck.poll("the \(surface.menuTitle) menu item", within: .seconds(2), {
                let roots = AX.elements(item, kAXChildrenAttribute)
                if let identifier = surface.menuIdentifier, let entry = AX.find(identifier, in: roots) { return entry }
                return findByTitle(surface.menuTitle, in: roots)
            }) {
                return entry
            }
            HistoryCheck.key(53)
        }
        throw HarnessError("the menu did not show its \(surface.menuTitle) item")
    }

    private static func usableWindow(_ surface: Surface, app: AXUIElement,
                                     every interval: Duration = .milliseconds(20)) async throws -> AXUIElement {
        try await HistoryCheck.poll("a usable \(surface.receiptName) window", every: interval) {
            guard let window = AX.find(surface.windowIdentifier, in: AX.elements(app, kAXWindowsAttribute), depth: 0) else {
                return nil
            }
            switch surface {
            case .settings:
                guard (try? requireSettingsForm(window)) != nil else { return nil }
            case .history:
                guard let table = AX.find(AccessibilityID.historyTable, in: [window]),
                      !AX.elements(table, kAXVisibleRowsAttribute).isEmpty else { return nil }
            }
            return window
        }
    }

    private static func requireSettingsForm(_ window: AXUIElement) throws {
        guard AX.find(AccessibilityID.settingsGrid, in: [window]) != nil else {
            throw HarnessError("Settings has no accessible Keys grid")
        }
        for id in rowIDs {
            guard elementIfPresent(AccessibilityID.settingsEntry(id), in: window) != nil,
                  elementIfPresent(AccessibilityID.settingsStatus(id), in: window) != nil,
                  elementIfPresent(AccessibilityID.settingsSave(id), in: window) != nil,
                  elementIfPresent(AccessibilityID.settingsRemove(id), in: window) != nil else {
                throw HarnessError("Settings is missing a canonical Keys row control")
            }
        }
    }

    private static func requireSameSingleWindow(_ window: AXUIElement, app: AXUIElement) throws {
        guard windowCount(.settings, app: app) == 1,
              AX.string(window, kAXIdentifierAttribute) == AccessibilityID.settingsWindow else {
            throw HarnessError("opening Settings again did not reuse one Settings window")
        }
    }

    private static func closeWindow(_ surface: Surface, app: ReleaseApp) async throws {
        guard let window = AX.find(surface.windowIdentifier, in: AX.elements(app.element, kAXWindowsAttribute), depth: 0) else {
            throw HarnessError("the measured \(surface.receiptName) window disappeared")
        }
        try await close(window, identifier: surface.windowIdentifier, app: app.element)
    }

    private static func close(_ window: AXUIElement, identifier: String, app: AXUIElement) async throws {
        guard let button = AX.element(window, kAXCloseButtonAttribute) else {
            throw HarnessError("the \(identifier) window has no close button")
        }
        try press(button)
        _ = try await HistoryCheck.poll("the \(identifier) window to close") {
            AX.find(identifier, in: AX.elements(app, kAXWindowsAttribute), depth: 0) == nil ? true : nil
        }
    }

    private static func windowCount(_ surface: Surface, app: AXUIElement) -> Int {
        AX.elements(app, kAXWindowsAttribute).filter {
            AX.string($0, kAXIdentifierAttribute) == surface.windowIdentifier
        }.count
    }

    private static func element(_ identifier: String, in window: AXUIElement) throws -> AXUIElement {
        guard let element = elementIfPresent(identifier, in: window) else {
            throw HarnessError("Settings has no control \(identifier)")
        }
        return element
    }

    private static func elementIfPresent(_ identifier: String, in window: AXUIElement) -> AXUIElement? {
        AX.find(identifier, in: [window])
    }

    private static var rowIDs: [CredentialID] {
        CloudModel.allCases.map(CredentialID.speech) + [.cleanup, .jev]
    }

    private static func saveSynthetic(_ value: String, in window: AXUIElement, app: AXUIElement,
                                     pid: pid_t, label: String) async throws {
        let entry = try element(AccessibilityID.settingsEntry(syntheticCredential), in: window)
        let button = try element(AccessibilityID.settingsSave(syntheticCredential), in: window)
        try AX.set(entry, kAXValueAttribute, value as CFString)
        try press(button)
        try await waitForStatus("Saved", for: syntheticCredential, in: window)
        let fields = try await inspectFixture()
        guard fields.fieldsAreEmpty, fields.pid == pid, try processID(of: app) == pid else {
            throw HarnessError("the \(label) did not clear the secure entry in the same process")
        }
    }

    private static func waitForStatus(_ expected: String, for id: CredentialID, in window: AXUIElement) async throws {
        _ = try await HistoryCheck.poll("Settings status \(expected)") { () async throws -> Bool? in
            guard let status = elementIfPresent(AccessibilityID.settingsStatus(id), in: window),
                  let value = AX.string(status, kAXValueAttribute) else { return nil }
            if value == "Unavailable" || value == "Could not change key" {
                let observation = try await inspectFixture()
                throw HarnessError(observation.unavailableDescription
                    ?? "Unavailable/unrun: fixture operation unavailable; lease retained.")
            }
            guard value == expected else { return nil }
            return true
        }
    }

    private static func inspectFixture() async throws -> TestHookSettingsFixture {
        try await sendFixture(.settingsFixtureInspect)
    }

    private static func sendFixture(_ command: TestHookCommand) async throws -> TestHookSettingsFixture {
        switch try await DevApp.hooks.send(command, timeout: .seconds(10)) {
        case .settingsFixture(let observation): return observation
        case .failed: throw HarnessError("the Settings fixture operation was refused")
        default: throw HarnessError("unexpected reply to the Settings fixture command")
        }
    }

    private static func waitForFixture(phase: TestHookSettingsFixture.Phase,
                                       lastPhase: String) async throws -> TestHookSettingsFixture {
        var observedPhase = lastPhase
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let observation = try await inspectFixture()
            observedPhase = observation.phase.rawValue
            if observation.phase == phase { return observation }
            if observation.outcome != .ok || observation.phase == .refused || observation.phase == .stranded {
                throw HarnessError("the Settings fixture became unavailable at phase \(observation.phase.rawValue)")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HarnessError("the Settings fixture did not reach phase \(phase.rawValue); last observed phase was \(observedPhase)")
    }

    private static func requireObservation(
        _ observation: TestHookSettingsFixture,
        phase: TestHookSettingsFixture.Phase,
        pid: pid_t,
        fieldsEmpty: Bool,
        outcome: TestHookSettingsFixture.Outcome = .ok,
        cache: TestHookSettingsFixture.Cache? = nil,
        item: TestHookSettingsFixture.OwnedItem? = nil
    ) throws {
        guard observation.phase == phase, observation.outcome == outcome,
              observation.pid == pid, observation.fieldsAreEmpty == fieldsEmpty,
              cache.map({ observation.cache == $0 }) ?? true,
              item.map({ observation.item == $0 }) ?? true else {
            throw HarnessError("the Settings fixture observation did not match its expected bounded state")
        }
    }

    private static func writeReceipt(options: (surface: Surface, head: String, out: URL, runs: Int),
                                     app: ReleaseApp, samples: [Int], menuToWindow: [Int]) throws {
        let directory = options.out.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = options.surface.receiptName
        var lines = [
            "# Lexicon Settings open receipt",
            "# surface=\(options.surface.rawValue)",
            "# label=\(name)",
            "# reviewed_head=\(app.reviewedHead)",
            "# source_head=\(app.sourceHead)",
            "# build_head=\(app.buildHead)",
            "# bundle=\(app.bundlePath)",
            "# pid=\(app.pid)",
            "# timing_boundary=asked_to_open_to_drawn_app_log",
            "# first_ms=\(samples[0])"
        ]
        lines += samples.dropFirst().enumerated().map { "# repeated_\($0.offset + 1)_ms=\($0.element)" }
        lines += menuToWindow.enumerated().map { "# context_menu_to_window_\($0.offset)_ms=\($0.element)" }
        lines += samples.map(String.init)
        try (lines.joined(separator: "\n") + "\n").write(to: options.out, atomically: true, encoding: .utf8)
    }

    /// The app's own open-to-drawn times for this pid since `since`, one per show, in
    /// order. The log store can lag the window, so it is read until all `count` are there.
    private static func drawnTimes(_ surface: Surface, pid: pid_t, since: Date, count: Int) async throws -> [Int] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let predicate = "subsystem == \"Lexicon\" && category == \"\(surface.logCategory)\" && processID == \(pid)"
        return try await HistoryCheck.poll("\(count) \(surface.receiptName) open times in the app's log",
                                           every: .milliseconds(500), within: .seconds(15)) { () -> [Int]? in
            let (status, text) = try await runChild("/usr/bin/log", ["show", "--start", formatter.string(from: since),
                                                                      "--style", "compact", "--predicate", predicate])
            guard status == 0 else { throw HarnessError("log show exited \(status)") }
            let times = text.split(separator: "\n").compactMap { line in
                line.firstMatch(of: surface.drawnLine).flatMap { Int($0.1) }
            }
            guard times.count <= count else {
                throw HarnessError("the app logged \(times.count) \(surface.receiptName) opens for \(count) shows")
            }
            return times.count == count ? times : nil
        }
    }

    private static func press(_ element: AXUIElement) throws {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw HarnessError("press failed (AXError \(result.rawValue))") }
    }

    private static func requireSameProcess(_ element: AXUIElement, pid: pid_t) throws {
        guard try processID(of: element) == pid else {
            throw HarnessError("Settings is not in the expected Lexicon Dev process")
        }
    }

    private static func processID(of element: AXUIElement) throws -> pid_t {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        guard result == .success else {
            throw HarnessError("cannot read the Lexicon Dev process identifier")
        }
        return pid
    }

    private static func findByTitle(_ title: String, in roots: [AXUIElement]) -> AXUIElement? {
        for root in roots {
            if AX.string(root, kAXTitleAttribute) == title { return root }
            if let found = findByTitle(title, in: AX.elements(root, kAXChildrenAttribute)) { return found }
        }
        return nil
    }
}
#endif
