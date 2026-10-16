import AppKit
import Darwin
import LexiconCore
import LexiconDomain
import LexiconUI
import Testing

private struct CredentialRequest: Sendable {
    let edit: CredentialEdit
    let reply: @Sendable (CredentialOutcome) -> Void
}

/// NSLock protects requests and continuations while callbacks arrive off the main actor.
private final class CredentialCommandProbe: @unchecked Sendable {
    private struct Waiter {
        let matches: @Sendable (CredentialEdit) -> Bool
        let occurrence: Int
        let continuation: CheckedContinuation<CredentialRequest, Never>
    }

    private let lock = NSLock()
    private var requests: [CredentialRequest] = []
    private var waiters: [Waiter] = []

    func submit(_ edit: CredentialEdit, reply: @escaping @Sendable (CredentialOutcome) -> Void) {
        let request = CredentialRequest(edit: edit, reply: reply)
        lock.lock()
        requests.append(request)
        let ready = waiters.filter { waiter in
            waiter.matches(edit) && requests.filter { waiter.matches($0.edit) }.count > waiter.occurrence
        }
        waiters.removeAll { waiter in
            waiter.matches(edit) && requests.filter { waiter.matches($0.edit) }.count > waiter.occurrence
        }
        lock.unlock()
        ready.forEach { $0.continuation.resume(returning: request) }
    }

    func request(
        where matches: @escaping @Sendable (CredentialEdit) -> Bool,
        occurrence: Int = 0
    ) async -> CredentialRequest {
        await withCheckedContinuation { continuation in
            lock.lock()
            let found = requests.filter { matches($0.edit) }.dropFirst(occurrence).first
            if let found {
                lock.unlock()
                continuation.resume(returning: found)
                return
            }
            waiters.append(Waiter(matches: matches, occurrence: occurrence, continuation: continuation))
            lock.unlock()
        }
    }
}

@MainActor
private func view(withID identifier: String, in window: NSWindow) -> NSView? {
    func search(_ view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for child in view.subviews {
            if let match = search(child) { return match }
        }
        return nil
    }
    guard let contentView = window.contentView else { return nil }
    return search(contentView)
}

/// Walks the accessibility tree as an assistive app reads it, not the view tree:
/// a view that is not an accessibility element is skipped and its children promoted.
@MainActor
private func accessibilityElement(withID identifier: String, under root: Any) -> NSAccessibilityProtocol? {
    guard let root = root as? NSAccessibilityProtocol else { return nil }
    for child in root.accessibilityChildren() ?? [] {
        guard let element = child as? NSAccessibilityProtocol else { continue }
        if element.accessibilityIdentifier() == identifier { return element }
        if let match = accessibilityElement(withID: identifier, under: element) { return match }
    }
    return nil
}

@MainActor
private func settingsWindows() -> [NSWindow] {
    NSApp.windows.filter { $0.isVisible && view(withID: AccessibilityID.settingsGrid, in: $0) != nil }
}

@MainActor
private func performSettingsMenuAction(_ menu: NSMenu) {
    menu.performActionForItem(at: 0)
}

/// A callback may enqueue its bounded result on MainActor. This main-queue block
/// is the deterministic signal that work queued by the preceding reply has run.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

private func isAvailability(_ edit: CredentialEdit, for id: CredentialID) -> Bool {
    guard case .availability(let actual) = edit else { return false }
    return actual == id
}

private func isSave(_ edit: CredentialEdit, for id: CredentialID, value: String) -> Bool {
    guard case .save(let actualID, let actualValue) = edit else { return false }
    return actualID == id && actualValue == value
}

private func isRemove(_ edit: CredentialEdit, for id: CredentialID) -> Bool {
    guard case .remove(let actual) = edit else { return false }
    return actual == id
}

// AppKit needs an application loop outside the main dispatch queue. Starting
// it from a run-loop block leaves MainActor free to run the asynchronous check.
private func runNativeCheck(_ body: @escaping @MainActor () async throws -> Void) async -> Never {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                let application = NSApplication.shared
                application.setActivationPolicy(.prohibited)
                Task { @MainActor in
                    do {
                        try await body()
                        exit(73)
                    } catch {
                        Issue.record(error)
                        exit(74)
                    }
                }
                application.run()
                Issue.record("Native application loop returned before the check completed")
                continuation.resume()
            }
        }
        CFRunLoopWakeUp(runLoop)
    }
    exit(74)
}

@Suite(.serialized)
struct SettingsWindowTests {
// AppKit state is process-global, so every native check runs in its own child.
// Exit 73 is reached only after the full body completes; expectation issues are forwarded.
@Test(.timeLimit(.minutes(1))) func pendingCredentialCallbacksLeaveTheNativeGridUsable() async throws {
    await #expect(processExitsWith: .exitCode(73)) {
        await runNativeCheck { try await Self.pendingCredentialCallbacksLeaveTheNativeGridUsableBody() }
    }
}

@MainActor
private static func pendingCredentialCallbacksLeaveTheNativeGridUsableBody() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let probe = CredentialCommandProbe()
    let presenter = SettingsWindowPresenter(credentials: { edit, reply in
        probe.submit(edit, reply: reply)
    })
    let menu = NSMenu()
    let item = presenter.menuItem()
    menu.addItem(item)

    performSettingsMenuAction(menu)
    let pendingLookup = await probe.request { if case .availability = $0 { true } else { false } }
    let window = try #require(settingsWindows().first)
    let grid = try #require(view(withID: AccessibilityID.settingsGrid, in: window) as? NSGridView)
    #expect(isAvailability(pendingLookup.edit, for: .speech(CloudModel.allCases[0])))
    #expect(window.accessibilityIdentifier() == AccessibilityID.settingsWindow)
    #expect(grid.accessibilityIdentifier() == AccessibilityID.settingsGrid)
    #expect(item.accessibilityIdentifier() == AccessibilityID.settingsMenu)
    window.contentView?.layoutSubtreeIfNeeded()

    let ids: [CredentialID] = CloudModel.allCases.map { .speech($0) } + [.cleanup, .jev]
    for id in ids {
        let secureEntry = try #require(view(withID: AccessibilityID.settingsEntry(id), in: window) as? NSSecureTextField)
        #expect(secureEntry.frame.width > 0)
        #expect(secureEntry.frame.height > 0)
        #expect(view(withID: AccessibilityID.settingsSave(id), in: window) is NSButton)
        #expect(view(withID: AccessibilityID.settingsRemove(id), in: window) is NSButton)
        #expect(view(withID: AccessibilityID.settingsStatus(id), in: window) is NSTextField)
    }

    // The initial availability result is still held. The form remains usable and
    // Save and Remove travel through distinct credential commands.
    let id = CredentialID.jev
    let field = try #require(view(withID: AccessibilityID.settingsEntry(id), in: window) as? NSSecureTextField)
    field.stringValue = "synthetic-settings-key"
    let save = try #require(view(withID: AccessibilityID.settingsSave(id), in: window) as? NSButton)
    save.performClick(nil)
    let saveRequest = await probe.request { isSave($0, for: id, value: "synthetic-settings-key") }
    let saveRequestMatches = isSave(saveRequest.edit, for: id, value: "synthetic-settings-key")
    #expect(saveRequestMatches)
    let entryWasCleared1 = field.stringValue.isEmpty
    #expect(entryWasCleared1)
    #if DEBUG
    #expect(presenter.credentialFieldsAreEmpty)
    #endif

    let remove = try #require(view(withID: AccessibilityID.settingsRemove(id), in: window) as? NSButton)
    remove.performClick(nil)
    let removeRequest = await probe.request { isRemove($0, for: id) }
    #expect(isRemove(removeRequest.edit, for: id))

    // An empty Save remains a Save request; it cannot silently become Remove.
    save.performClick(nil)
    let emptySave = await probe.request { isSave($0, for: id, value: "") }
    let emptySaveRemainsSave = isSave(emptySave.edit, for: id, value: "")
    #expect(emptySaveRemainsSave)
    #expect(!isRemove(emptySave.edit, for: id))

    window.performClose(nil)
}

@Test(.timeLimit(.minutes(1))) func theKeysGridHoldsEveryRowInTheAccessibilityTree() async throws {
    await #expect(processExitsWith: .exitCode(73)) {
        await runNativeCheck { try await Self.theKeysGridHoldsEveryRowInTheAccessibilityTreeBody() }
    }
}

// The Live checks harness finds the form through the accessibility tree, so the
// grid has to be an element there with each row's controls beneath it.
@MainActor
private static func theKeysGridHoldsEveryRowInTheAccessibilityTreeBody() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let presenter = SettingsWindowPresenter(credentials: { _, _ in })
    let menu = NSMenu()
    menu.addItem(presenter.menuItem())

    performSettingsMenuAction(menu)
    let window = try #require(settingsWindows().first)
    let grid = try #require(accessibilityElement(withID: AccessibilityID.settingsGrid, under: window))
    let ids: [CredentialID] = CloudModel.allCases.map { .speech($0) } + [.cleanup, .jev]
    for id in ids {
        for control in [AccessibilityID.settingsEntry(id), AccessibilityID.settingsStatus(id),
                        AccessibilityID.settingsSave(id), AccessibilityID.settingsRemove(id)] {
            #expect(accessibilityElement(withID: control, under: grid) != nil, "\(control)")
        }
    }
    window.performClose(nil)
}

@Test(.timeLimit(.minutes(1))) func oneSettingsWindowIsReusedAndReopeningStartsWithBlankFields() async throws {
    await #expect(processExitsWith: .exitCode(73)) {
        await runNativeCheck { try await Self.oneSettingsWindowIsReusedAndReopeningStartsWithBlankFieldsBody() }
    }
}

@MainActor
private static func oneSettingsWindowIsReusedAndReopeningStartsWithBlankFieldsBody() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let probe = CredentialCommandProbe()
    let presenter = SettingsWindowPresenter(credentials: { edit, reply in
        probe.submit(edit, reply: reply)
    })
    let menu = NSMenu()
    let item = presenter.menuItem()
    menu.addItem(item)

    performSettingsMenuAction(menu)
    let firstWindow = try #require(settingsWindows().first)
    let firstField = try #require(view(withID: AccessibilityID.settingsEntry(.jev), in: firstWindow) as? NSSecureTextField)
    #expect(firstWindow.makeFirstResponder(firstField))
    let firstEditor = try #require(firstField.currentEditor() as? NSTextView)
    firstEditor.string = "synthetic-settings-key"

    performSettingsMenuAction(menu)
    #expect(settingsWindows().count == 1)
    #expect(settingsWindows().first === firstWindow)

    firstWindow.performClose(nil)
    let entryWasCleared2 = firstField.stringValue.isEmpty
    #expect(entryWasCleared2)
    let entryWasCleared3 = firstEditor.string.isEmpty
    #expect(entryWasCleared3)
    #expect(settingsWindows().isEmpty)
    #if DEBUG
    #expect(presenter.credentialFieldsAreEmpty)
    #endif

    performSettingsMenuAction(menu)
    let reopenedWindow = try #require(settingsWindows().first)
    #expect(reopenedWindow !== firstWindow)
    let reopenedField = try #require(view(withID: AccessibilityID.settingsEntry(.jev), in: reopenedWindow) as? NSSecureTextField)
    let entryWasCleared4 = reopenedField.stringValue.isEmpty
    #expect(entryWasCleared4)
    #if DEBUG
    #expect(presenter.credentialFieldsAreEmpty)
    #endif

    reopenedWindow.performClose(nil)
}

@Test(.timeLimit(.minutes(1))) func savingClearsTheActiveSecureFieldEditorSynchronously() async throws {
    await #expect(processExitsWith: .exitCode(73)) {
        await runNativeCheck { try await Self.savingClearsTheActiveSecureFieldEditorSynchronouslyBody() }
    }
}

@MainActor
private static func savingClearsTheActiveSecureFieldEditorSynchronouslyBody() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let probe = CredentialCommandProbe()
    let presenter = SettingsWindowPresenter(credentials: { edit, reply in
        probe.submit(edit, reply: reply)
    })
    let menu = NSMenu()
    let item = presenter.menuItem()
    menu.addItem(item)

    performSettingsMenuAction(menu)
    let window = try #require(settingsWindows().first)
    let id = CredentialID.jev
    let field = try #require(view(withID: AccessibilityID.settingsEntry(id), in: window) as? NSSecureTextField)
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.string = "synthetic-settings-key"
    let save = try #require(view(withID: AccessibilityID.settingsSave(id), in: window) as? NSButton)

    save.performClick(nil)

    let entryWasCleared5 = field.stringValue.isEmpty
    #expect(entryWasCleared5)
    let entryWasCleared6 = editor.string.isEmpty
    #expect(entryWasCleared6)
    #if DEBUG
    #expect(presenter.credentialFieldsAreEmpty)
    #endif
    let submitted = await probe.request { isSave($0, for: id, value: "synthetic-settings-key") }
    let submittedValueMatches = isSave(submitted.edit, for: id, value: "synthetic-settings-key")
    #expect(submittedValueMatches)
    window.performClose(nil)
}

@Test(.timeLimit(.minutes(1))) func oldCredentialResultsCannotReplaceNewerResultsAfterReopen() async throws {
    await #expect(processExitsWith: .exitCode(73)) {
        await runNativeCheck { try await Self.oldCredentialResultsCannotReplaceNewerResultsAfterReopenBody() }
    }
}

@MainActor
private static func oldCredentialResultsCannotReplaceNewerResultsAfterReopenBody() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let probe = CredentialCommandProbe()
    let presenter = SettingsWindowPresenter(credentials: { edit, reply in
        probe.submit(edit, reply: reply)
    })
    let menu = NSMenu()
    menu.addItem(presenter.menuItem())
    let id = CredentialID.jev

    performSettingsMenuAction(menu)
    let firstAvailability = await probe.request(where: { isAvailability($0, for: id) }, occurrence: 0)
    let firstWindow = try #require(settingsWindows().first)
    let firstField = try #require(view(withID: AccessibilityID.settingsEntry(id), in: firstWindow) as? NSSecureTextField)
    firstField.stringValue = "older-synthetic-key"
    let firstSaveButton = try #require(view(withID: AccessibilityID.settingsSave(id), in: firstWindow) as? NSButton)
    firstSaveButton.performClick(nil)
    let firstSave = await probe.request(where: { isSave($0, for: id, value: "older-synthetic-key") })

    firstWindow.performClose(nil)
    let entryWasCleared7 = firstField.stringValue.isEmpty
    #expect(entryWasCleared7)

    performSettingsMenuAction(menu)
    let secondAvailability = await probe.request(where: { isAvailability($0, for: id) }, occurrence: 1)
    let secondWindow = try #require(settingsWindows().first)
    let secondField = try #require(view(withID: AccessibilityID.settingsEntry(id), in: secondWindow) as? NSSecureTextField)
    let status = try #require(view(withID: AccessibilityID.settingsStatus(id), in: secondWindow) as? NSTextField)
    let statusBeforeSave = status.stringValue
    secondField.stringValue = "newer-synthetic-key"
    let secondSaveButton = try #require(view(withID: AccessibilityID.settingsSave(id), in: secondWindow) as? NSButton)
    secondSaveButton.performClick(nil)
    let secondSave = await probe.request(where: { isSave($0, for: id, value: "newer-synthetic-key") })

    secondSave.reply(.saved)
    await drainMainQueue()
    let statusAfterSave = status.stringValue
    #expect(statusAfterSave != statusBeforeSave)
    let statusDoesNotExposeSubmittedText = !statusAfterSave.contains("newer-synthetic-key")
    #expect(statusDoesNotExposeSubmittedText)

    // Deliver old-form and pre-save availability replies after the newer save.
    firstSave.reply(.refused)
    firstAvailability.reply(.availability(.missing))
    secondAvailability.reply(.availability(.missing))
    await drainMainQueue()
    #expect(status.stringValue == statusAfterSave)
    let entryWasCleared8 = secondField.stringValue.isEmpty
    #expect(entryWasCleared8)
    secondWindow.performClose(nil)
}
}
