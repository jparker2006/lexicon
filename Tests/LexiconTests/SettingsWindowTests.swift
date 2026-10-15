import AppKit
import LexiconCore
import LexiconDomain
import LexiconUI
import Testing

private struct CredentialRequest: Sendable {
    let edit: CredentialEdit
    let reply: @Sendable (CredentialOutcome) -> Void
}

/// Keeps the presenter-facing command real while making every result wait for the test.
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

@MainActor
private func settingsWindows() -> [NSWindow] {
    NSApp.windows.filter { $0.isVisible && view(withID: AccessibilityID.settingsGrid, in: $0) != nil }
}

@MainActor
private func performSettingsMenuAction(_ menu: NSMenu) {
    #expect(menu.performActionForItem(at: 0))
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

@Suite(.serialized)
struct SettingsWindowTests {
@MainActor
@Test(.timeLimit(.minutes(1))) func pendingCredentialCallbacksLeaveTheNativeGridUsable() async throws {
    _ = NSApplication.shared
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

    let ids: [CredentialID] = CloudModel.allCases.map { .speech($0) } + [.cleanup, .jev]
    for id in ids {
        #expect(view(withID: AccessibilityID.settingsEntry(id), in: window) is NSSecureTextField)
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
    #expect(isSave(saveRequest.edit, for: id, value: "synthetic-settings-key"))
    #expect(field.stringValue.isEmpty)
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
    #expect(isSave(emptySave.edit, for: id, value: ""))
    #expect(!isRemove(emptySave.edit, for: id))

    window.performClose(nil)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func oneSettingsWindowIsReusedAndReopeningStartsWithBlankFields() throws {
    _ = NSApplication.shared
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
    #expect(firstField.stringValue.isEmpty)
    #expect(firstEditor.string.isEmpty)
    #expect(settingsWindows().isEmpty)
    #if DEBUG
    #expect(presenter.credentialFieldsAreEmpty)
    #endif

    performSettingsMenuAction(menu)
    let reopenedWindow = try #require(settingsWindows().first)
    #expect(reopenedWindow !== firstWindow)
    let reopenedField = try #require(view(withID: AccessibilityID.settingsEntry(.jev), in: reopenedWindow) as? NSSecureTextField)
    #expect(reopenedField.stringValue.isEmpty)
    #if DEBUG
    #expect(presenter.credentialFieldsAreEmpty)
    #endif

    reopenedWindow.performClose(nil)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func savingClearsTheActiveSecureFieldEditorSynchronously() async throws {
    _ = NSApplication.shared
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

    #expect(field.stringValue.isEmpty)
    #expect(editor.string.isEmpty)
    #if DEBUG
    #expect(presenter.credentialFieldsAreEmpty)
    #endif
    let submitted = await probe.request { isSave($0, for: id, value: "synthetic-settings-key") }
    #expect(isSave(submitted.edit, for: id, value: "synthetic-settings-key"))
    window.performClose(nil)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func oldCredentialResultsCannotReplaceNewerResultsAfterReopen() async throws {
    _ = NSApplication.shared
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
    #expect(firstField.stringValue.isEmpty)

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
    #expect(!statusAfterSave.contains("newer-synthetic-key"))

    // Deliver old-form and pre-save availability replies after the newer save.
    firstSave.reply(.refused)
    firstAvailability.reply(.availability(.missing))
    secondAvailability.reply(.availability(.missing))
    await drainMainQueue()
    #expect(status.stringValue == statusAfterSave)
    #expect(secondField.stringValue.isEmpty)
    secondWindow.performClose(nil)
}
}
