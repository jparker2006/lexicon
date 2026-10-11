import Foundation
import Testing
import LexiconDomain
import LexiconCore

// First-run setup's model download goes through `CloudAccess` like every
// network use (#5, #57): Private mode blocks it, and turning Private mode on
// mid-download cancels it. The fake download only waits for its cancellation,
// so no test touches the network or depends on machine speed.

/// A download that reports it started, then runs until it is cancelled.
private struct HangingDownload: Sendable {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    init() { (started, signal) = AsyncStream<Void>.makeStream() }

    /// Throws `CancellationError` once cancelled; never returns otherwise.
    func run() async throws -> Int {
        signal.yield()
        try await Task.sleep(for: .seconds(86_400))
        return 0
    }
}

/// A model download needs no key.
private func openAccess() throws -> CloudAccess {
    try #require(CloudAccess.granted(by: .defaults, app: .unknown, keys: noKeys))
}

private let noKeys: @Sendable (CredentialID) -> String? = { _ in nil }

private func withStore(_ body: (PreferencesStore) async throws -> Void) async rethrows {
    let name = "lexicon.tests.\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }
    try await body(PreferencesStore(defaults: suite))
}

@Test func aDownloadUnderUntouchedAccessFinishes() async throws {
    let access = try openAccess()
    #expect(try await access.untilRevoked { 42 } == 42)
}

@Test func revokingAccessCancelsTheDownloadMidway() async throws {
    let access = try openAccess()
    let download = HangingDownload()
    let running = Task { try await access.untilRevoked { try await download.run() } }
    for await _ in download.started { break }
    access.revoke(.privateModeOn)
    await #expect(throws: CloudAccessRevoked(.privateModeOn)) { try await running.value }
}

@Test func revokedAccessNeverStartsTheDownload() async throws {
    let access = try openAccess()
    access.revoke(.privateModeOn)
    await #expect(throws: CloudAccessRevoked(.privateModeOn)) {
        try await access.untilRevoked { () -> Int in Issue.record("the download started"); return 0 }
    }
}

@Test func privateModeBlocksAModelDownload() async throws {
    try await withStore { store in
        store.update { $0.privacy = .private }
        await #expect(throws: CloudAccessRevoked(.privateModeOn)) {
            try await store.downloading { _ -> Int in Issue.record("the download started"); return 0 }
        }
    }
}

@Test func turningPrivateModeOnMidDownloadStopsIt() async throws {
    try await withStore { store in
        let download = HangingDownload()
        let running = Task { try await store.downloading { access in try await access.untilRevoked { try await download.run() } } }
        for await _ in download.started { break }
        store.update { $0.privacy = .private }
        await #expect(throws: CloudAccessRevoked(.privateModeOn)) { try await running.value }
    }
}

@Test func anotherSettingChangedMidDownloadLeavesItRunning() async throws {
    try await withStore { store in
        let (started, start) = AsyncStream<Void>.makeStream()
        let (finish, finished) = AsyncStream<Void>.makeStream()
        let running = Task {
            try await store.downloading { access in
                try await access.untilRevoked {
                    start.yield()
                    for await _ in finish { break }
                    return access.revoked == nil
                }
            }
        }
        for await _ in started { break }
        store.update { $0.soundsOn = false }
        finished.yield()
        let stillGranted = try await running.value
        #expect(stillGranted)
    }
}
