#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import LexiconCore
import LexiconDomain

private func fixtureService() -> String {
    "dev.jparker.lexicon.settings-fixture-tests.\(UUID().uuidString)"
}

private func editOutcome(from command: CredentialCommand, _ edit: CredentialEdit) async -> CredentialOutcome {
    await withCheckedContinuation { continuation in
        command(edit) { continuation.resume(returning: $0) }
    }
}

private func fixtureObservation(from secrets: Secrets, _ action: SettingsFixtureAction) async -> SettingsFixtureObservation {
    await withCheckedContinuation { continuation in
        secrets.settingsFixture(action) { continuation.resume(returning: $0) }
    }
}

private final class ReadGate: Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let releaseRead = DispatchSemaphore(value: 0)
    private let firstRead = Mutex(true)
    private let releaseOutcome = Mutex<DispatchTimeoutResult?>(nil)

    func blockRead() {
        let shouldBlock = firstRead.withLock { first -> Bool in
            defer { first = false }
            return first
        }
        guard shouldBlock else { return }
        started.signal()
        let released = releaseRead.wait(timeout: .now() + 5) // timing-ok: deadline bounds a missing explicit release
        releaseOutcome.withLock { $0 = released }
    }

    func waitUntilReadStarts(until deadline: DispatchTime = .now() + 5) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: started.wait(timeout: deadline)) // timing-ok: deadline bounds a missing explicit read-start signal
            }
        }
    }
    var readWasReleased: Bool { releaseOutcome.withLock { $0 == .success } }
    func release() { releaseRead.signal() }
}

@Test func readGateReportsAnExpiredStartDeadline() async {
    let gate = ReadGate()
    let result = await gate.waitUntilReadStarts(until: .now())

    #expect(result == .timedOut)
}

private final class ScriptedSecurity: Sendable {
    private struct Item: Sendable {
        let service: String
        let account: String
        var marker: Data?
        var value: String
    }

    private struct State: Sendable {
        var readResults: [CredentialSecurity.Read] = []
        var normalItems: [String: Item] = [:]
        var ownedItems: [Data: Item] = [:]
        var addResult: CredentialSecurity.OwnedAdd = .created(Data([0x31, 0x37]))
        var hideOwnedReference = false
        var failReplace = false
        var failRemove = false
        var readCount = 0
        var presenceCount = 0
        var writeCount = 0
        var addCount = 0
        var ownedPresenceCount = 0
        var replaceCount = 0
        var removeCount = 0
        var ownedOperationsUsedIssuedReference = true
        var ownedOperationsUsedIssuedMarker = true
        var issuedMarker: Data?
    }

    struct Counts: Sendable {
        let reads: Int
        let presence: Int
        let writes: Int
        let adds: Int
        let ownedPresence: Int
        let replacements: Int
        let removals: Int
        let usedIssuedReference: Bool
        let usedIssuedMarker: Bool
    }

    private let state = Mutex(State())
    private let readGate: ReadGate?
    private let issuedReference = Data([0x31, 0x37])

    init(readGate: ReadGate? = nil) { self.readGate = readGate }

    var security: CredentialSecurity {
        CredentialSecurity(
            read: { [self] service, account in read(service: service, account: account) },
            presence: { [self] service, account in presence(service: service, account: account) },
            write: { [self] service, account, value in write(service: service, account: account, value: value) },
            addOwned: { [self] service, account, value, marker in
                addOwned(service: service, account: account, value: value, marker: marker)
            },
            ownedPresence: { [self] reference, marker in ownedPresence(reference: reference, marker: marker) },
            replaceOwned: { [self] reference, marker, value in
                replaceOwned(reference: reference, marker: marker, value: value)
            },
            removeOwned: { [self] reference, marker in removeOwned(reference: reference, marker: marker) }
        )
    }

    func enqueueReads(_ reads: [CredentialSecurity.Read]) {
        state.withLock { $0.readResults.append(contentsOf: reads) }
    }

    func makeNextAddReturnNoReference() {
        state.withLock { $0.addResult = .created(nil) }
    }

    func makeNextAddDuplicate() {
        state.withLock { $0.addResult = .duplicate }
    }

    func hideOwnedReference() { state.withLock { $0.hideOwnedReference = true } }
    func failCleanup() { state.withLock { $0.failRemove = true } }
    func failReplacement() { state.withLock { $0.failReplace = true } }

    func changeOwnedMarker() {
        state.withLock { state in
            guard var item = state.ownedItems[issuedReference] else { return }
            item.marker = Data([0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x64])
            state.ownedItems[issuedReference] = item
        }
    }

    func counts() -> Counts {
        state.withLock {
            Counts(reads: $0.readCount, presence: $0.presenceCount, writes: $0.writeCount,
                   adds: $0.addCount, ownedPresence: $0.ownedPresenceCount, replacements: $0.replaceCount,
                   removals: $0.removeCount, usedIssuedReference: $0.ownedOperationsUsedIssuedReference,
                   usedIssuedMarker: $0.ownedOperationsUsedIssuedMarker)
        }
    }

    private func key(_ service: String, _ account: String) -> String { "\(service)/\(account)" }

    private func read(service: String, account: String) -> CredentialSecurity.Read {
        readGate?.blockRead()
        return state.withLock { state in
            state.readCount += 1
            guard !state.readResults.isEmpty else { return .missing }
            return state.readResults.removeFirst()
        }
    }

    private func presence(service: String, account: String) -> CredentialAvailability {
        state.withLock { state in
            state.presenceCount += 1
            return state.normalItems[key(service, account)] == nil ? .missing : .saved
        }
    }

    private func write(service: String, account: String, value: String?) -> Bool {
        state.withLock { state in
            state.writeCount += 1
            let key = key(service, account)
            if let value {
                state.normalItems[key] = Item(service: service, account: account, marker: nil, value: value)
            } else {
                state.normalItems[key] = nil
            }
            return true
        }
    }

    private func addOwned(service: String, account: String, value: String, marker: Data) -> CredentialSecurity.OwnedAdd {
        state.withLock { state in
            state.addCount += 1
            guard state.normalItems[key(service, account)] == nil else { return .duplicate }
            switch state.addResult {
            case .duplicate: return .duplicate
            case .failed: return .failed
            case .created(let reference):
                if let reference {
                    state.issuedMarker = marker
                    let item = Item(service: service, account: account, marker: marker, value: value)
                    state.ownedItems[reference] = item
                    state.normalItems[key(service, account)] = item
                }
                return .created(reference)
            }
        }
    }

    private func ownedPresence(reference: Data, marker: Data) -> Bool {
        state.withLock { state in
            state.ownedPresenceCount += 1
            recordOwnershipArguments(reference, marker, state: &state)
            guard !state.hideOwnedReference, let item = state.ownedItems[reference] else { return false }
            return item.marker == marker
        }
    }

    private func replaceOwned(reference: Data, marker: Data, value: String) -> Bool {
        state.withLock { state in
            state.replaceCount += 1
            recordOwnershipArguments(reference, marker, state: &state)
            guard !state.failReplace, !state.hideOwnedReference,
                  var item = state.ownedItems[reference], item.marker == marker else { return false }
            item.value = value
            state.ownedItems[reference] = item
            state.normalItems[key(item.service, item.account)] = item
            return true
        }
    }

    private func removeOwned(reference: Data, marker: Data) -> Bool {
        state.withLock { state in
            state.removeCount += 1
            recordOwnershipArguments(reference, marker, state: &state)
            guard !state.failRemove, !state.hideOwnedReference,
                  let item = state.ownedItems[reference], item.marker == marker else { return false }
            state.ownedItems[reference] = nil
            state.normalItems[key(item.service, item.account)] = nil
            return true
        }
    }

    private func recordOwnershipArguments(_ reference: Data, _ marker: Data, state: inout State) {
        state.ownedOperationsUsedIssuedReference = state.ownedOperationsUsedIssuedReference && reference == issuedReference
        let usedIssuedMarker = state.issuedMarker.map { $0 == marker } ?? false
        state.ownedOperationsUsedIssuedMarker = state.ownedOperationsUsedIssuedMarker && usedIssuedMarker
    }
}

@Test func fixtureGateRejectsAnOrdinaryThrowawayOwnerWithoutSecurityCalls() async {
    let service = "dev.jparker.lexicon.tests.\(UUID().uuidString)"
    let script = ScriptedSecurity()
    let secrets = Secrets(.keychain(service: service), security: script.security)

    let rejected = await fixtureObservation(from: secrets, .begin)
    let later = await fixtureObservation(from: secrets, .inspect)

    #expect(rejected.phase == .idle)
    #expect(rejected.outcome == .refused)
    #expect(later.phase == .idle)
    #expect(script.counts().reads == 0)
    #expect(script.counts().presence == 0)
    #expect(script.counts().adds == 0)
    #expect(script.counts().writes == 0)
}

@Test func fixtureBeginReservesWithoutReadingOrCreatingAnItem() async {
    let script = ScriptedSecurity()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    let observation = await fixtureObservation(from: secrets, .begin)

    #expect(observation.phase == .reserved)
    #expect(observation.outcome == .ok)
    #expect(observation.cache == .unknown)
    #expect(observation.item == .none)
    #expect(script.counts().reads == 0)
    #expect(script.counts().presence == 0)
    #expect(script.counts().adds == 0)
    #expect(script.counts().writes == 0)
}

@Test func duplicateFirstFixtureSaveRefusesWithoutChangingCachedMissingOrWriting() async {
    let script = ScriptedSecurity()
    script.makeNextAddDuplicate()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }
    let primedMissing = secrets.lookup(.jev) == nil
    let began = await fixtureObservation(from: secrets, .begin)
    let save = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-fixture-key"))
    let after = await fixtureObservation(from: secrets, .inspect)
    let ended = await fixtureObservation(from: secrets, .end)

    #expect(primedMissing)
    #expect(began.phase == .reserved)
    #expect(save == .refused)
    #expect(after.phase == .refused)
    #expect(after.cache == .missing)
    #expect(script.counts().adds == 1)
    #expect(script.counts().writes == 0)
    #expect(script.counts().removals == 0)
    #expect(ended.phase == .idle)
}

@Test func fixtureMutatesAndRemovesOnlyTheIssuedReference() async {
    let script = ScriptedSecurity()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    let began = await fixtureObservation(from: secrets, .begin)
    let saved = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-fixture-key"))
    let owned = await fixtureObservation(from: secrets, .inspect)
    let replacement = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-replacement-key"))
    let replaced = await fixtureObservation(from: secrets, .inspect)
    let removed = await editOutcome(from: secrets.credentials, .remove(.jev))
    let removedState = await fixtureObservation(from: secrets, .inspect)
    let ended = await fixtureObservation(from: secrets, .end)

    #expect(began.phase == .reserved)
    #expect(saved == .saved)
    #expect(owned.phase == .owned)
    #expect(owned.cache == .available)
    #expect(owned.item == .present)
    #expect(replacement == .saved)
    #expect(replaced.phase == .owned)
    #expect(removed == .removed)
    #expect(removedState.phase == .removed)
    #expect(removedState.cache == .missing)
    #expect(ended.phase == .idle)
    #expect(script.counts().adds == 1)
    #expect(script.counts().replacements == 1)
    #expect(script.counts().removals == 1)
    #expect(script.counts().usedIssuedReference)
    #expect(script.counts().usedIssuedMarker)
    #expect(script.counts().writes == 0)
}

@Test func missingOwnedReferenceRefusesReplacementAndEndWithoutUpsert() async {
    let script = ScriptedSecurity()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    _ = await fixtureObservation(from: secrets, .begin)
    _ = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-fixture-key"))
    script.hideOwnedReference()
    let replacement = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-replacement-key"))
    let removal = await editOutcome(from: secrets.credentials, .remove(.jev))
    let ending = await fixtureObservation(from: secrets, .end)
    let retained = await fixtureObservation(from: secrets, .inspect)

    #expect(replacement == .unavailable)
    #expect(removal == .unavailable)
    #expect(ending.phase == .owned)
    #expect(ending.outcome == .unavailable)
    #expect(retained.phase == .owned)
    #expect(retained.cache == .available)
    #expect(script.counts().adds == 1)
    #expect(script.counts().replacements == 0)
    #expect(script.counts().removals == 0)
    #expect(script.counts().usedIssuedReference)
    #expect(script.counts().writes == 0)
}

@Test func successfulAddWithoutReferenceStrandsFixtureWithoutCleanupAuthority() async {
    let script = ScriptedSecurity()
    script.makeNextAddReturnNoReference()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    let initiallyMissing = secrets.lookup(.jev) == nil
    #expect(initiallyMissing)
    _ = await fixtureObservation(from: secrets, .begin)
    let save = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-fixture-key"))
    let stranded = await fixtureObservation(from: secrets, .inspect)
    let retry = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-replacement-key"))
    let remove = await editOutcome(from: secrets.credentials, .remove(.jev))
    let end = await fixtureObservation(from: secrets, .end)

    #expect(save == .unavailable)
    #expect(stranded.phase == .stranded)
    #expect(stranded.cache == .missing)
    #expect(retry == .unavailable)
    #expect(remove == .unavailable)
    #expect(end.phase == .stranded)
    #expect(end.outcome == .unavailable)
    #expect(script.counts().adds == 1)
    #expect(script.counts().replacements == 0)
    #expect(script.counts().removals == 0)
    #expect(script.counts().writes == 0)
}

@Test func fixtureSuppressesItsCachedSyntheticKeyFromNormalLookup() async {
    let script = ScriptedSecurity()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    _ = await fixtureObservation(from: secrets, .begin)
    let saved = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-fixture-key"))
    let lookupWasSuppressed = secrets.lookup(.jev) == nil
    let observed = await fixtureObservation(from: secrets, .inspect)
    let ended = await fixtureObservation(from: secrets, .end)

    #expect(saved == .saved)
    #expect(lookupWasSuppressed)
    #expect(observed.phase == .owned)
    #expect(observed.cache == .available)
    #expect(script.counts().reads == 0)
    #expect(ended.phase == .idle)
}

@Test func readStartedBeforeACompleteFixtureCycleCannotRestoreItsOldValue() async throws {
    let gate = ReadGate()
    let script = ScriptedSecurity(readGate: gate)
    script.enqueueReads([.found("stale-synthetic-key"), .missing])
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    // Blocking the injected Security read must not occupy Swift's cooperative pool.
    let lookup = AsyncStream<Bool>.makeStream()
    DispatchQueue.global().async {
        lookup.continuation.yield(secrets.lookup(.jev) == nil)
        lookup.continuation.finish()
    }
    defer { gate.release() }
    let readStarted = await gate.waitUntilReadStarts()
    try #require(readStarted == .success)
    let began = await fixtureObservation(from: secrets, .begin)
    let ended = await fixtureObservation(from: secrets, .end)
    gate.release()
    var result = lookup.stream.makeAsyncIterator()
    let staleResultWasDiscarded = await result.next()
    let nextLookupWasStillMissing = secrets.lookup(.jev) == nil

    #expect(began.phase == .reserved)
    #expect(ended.phase == .idle)
    #expect(staleResultWasDiscarded == true)
    #expect(gate.readWasReleased)
    #expect(nextLookupWasStillMissing)
    #expect(script.counts().reads == 2)
}

@Test func endIsIdempotentAfterReferenceScopedCleanup() async {
    let script = ScriptedSecurity()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    _ = await fixtureObservation(from: secrets, .begin)
    _ = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-fixture-key"))
    let firstEnd = await fixtureObservation(from: secrets, .end)
    let secondEnd = await fixtureObservation(from: secrets, .end)

    #expect(firstEnd.phase == .idle)
    #expect(firstEnd.outcome == .ok)
    #expect(secondEnd.phase == .idle)
    #expect(secondEnd.outcome == .ok)
    #expect(script.counts().removals == 1)
    #expect(script.counts().usedIssuedReference)
    #expect(script.counts().usedIssuedMarker)
    #expect(script.counts().writes == 0)
}

@Test func failedFixtureCleanupRetainsTheLeaseAndSyntheticCache() async {
    let script = ScriptedSecurity()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    _ = await fixtureObservation(from: secrets, .begin)
    _ = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-fixture-key"))
    script.failCleanup()
    let end = await fixtureObservation(from: secrets, .end)
    let stillOwned = await fixtureObservation(from: secrets, .inspect)

    #expect(end.phase == .owned)
    #expect(end.outcome == .unavailable)
    #expect(stillOwned.phase == .owned)
    #expect(stillOwned.cache == .available)
    #expect(stillOwned.item == .present)
    #expect(script.counts().removals == 1)
    #expect(script.counts().writes == 0)
}

@Test func repeatedBeginKeepsAnOwnedFixtureLeaseAndItsReference() async {
    let script = ScriptedSecurity()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    _ = await fixtureObservation(from: secrets, .begin)
    _ = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-fixture-key"))
    let before = await fixtureObservation(from: secrets, .inspect)
    let repeatedBegin = await fixtureObservation(from: secrets, .begin)
    let replacement = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-replacement-key"))
    let after = await fixtureObservation(from: secrets, .inspect)
    let ended = await fixtureObservation(from: secrets, .end)

    #expect(before.phase == .owned)
    #expect(before.item == .present)
    #expect(before.cache == .available)
    #expect(repeatedBegin.phase == .owned)
    #expect(repeatedBegin.item == .present)
    #expect(repeatedBegin.cache == .available)
    #expect(replacement == .saved)
    #expect(after.phase == .owned)
    #expect(after.item == .present)
    #expect(ended.phase == .idle)
    #expect(script.counts().adds == 1)
    #expect(script.counts().replacements == 1)
    #expect(script.counts().removals == 1)
    #expect(script.counts().usedIssuedReference)
    #expect(script.counts().usedIssuedMarker)
    #expect(script.counts().writes == 0)
}

@Test func failedOwnedReplacementRetainsLeaseAndAvailableCacheState() async {
    let script = ScriptedSecurity()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    _ = await fixtureObservation(from: secrets, .begin)
    let firstSave = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-fixture-key"))
    script.failReplacement()
    let failedReplacement = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-replacement-key"))
    let after = await fixtureObservation(from: secrets, .inspect)
    let ended = await fixtureObservation(from: secrets, .end)

    #expect(firstSave == .saved)
    #expect(failedReplacement == .unavailable)
    #expect(after.phase == .owned)
    #expect(after.item == .present)
    #expect(after.cache == .available)
    #expect(ended.phase == .idle)
    #expect(script.counts().adds == 1)
    #expect(script.counts().replacements == 1)
    #expect(script.counts().removals == 1)
    #expect(script.counts().usedIssuedReference)
    #expect(script.counts().usedIssuedMarker)
    #expect(script.counts().writes == 0)
}

@Test func fixtureConstructorRejectsNonUUIDAndNoncanonicalServices() {
    let prefix = "dev.jparker.lexicon.settings-fixture-tests."
    let uuid = UUID().uuidString
    let invalidServices = [
        prefix + "not-a-uuid",
        prefix + uuid.lowercased(),
        prefix + uuid.replacingOccurrences(of: "-", with: ""),
        "dev.jparker.lexicon.tests.\(uuid)"
    ]

    let allRejected = invalidServices.allSatisfy { service in
        if case nil = Secrets.fixtureForTesting(service: service) { return true }
        return false
    }

    #expect(allRejected)
}

@Test func changedOwnedMarkerRefusesMutationAndCleanupWithoutLosingLease() async {
    let script = ScriptedSecurity()
    guard let secrets = Secrets.fixtureForTesting(service: fixtureService(), security: script.security) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }

    _ = await fixtureObservation(from: secrets, .begin)
    _ = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-fixture-key"))
    script.changeOwnedMarker()
    let replacement = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-replacement-key"))
    let removal = await editOutcome(from: secrets.credentials, .remove(.jev))
    let ending = await fixtureObservation(from: secrets, .end)
    let retained = await fixtureObservation(from: secrets, .inspect)

    #expect(replacement == .unavailable)
    #expect(removal == .unavailable)
    #expect(ending.phase == .owned)
    #expect(ending.outcome == .unavailable)
    #expect(retained.phase == .owned)
    #expect(retained.item == .unavailable)
    #expect(retained.cache == .available)
    #expect(script.counts().adds == 1)
    #expect(script.counts().replacements == 0)
    #expect(script.counts().removals == 0)
    #expect(script.counts().usedIssuedReference)
    #expect(script.counts().usedIssuedMarker)
    #expect(script.counts().writes == 0)
}

@Test func realThrowawayFixtureCreationAndEndDeleteOnlyItsPersistentReference() async {
    let service = fixtureService()
    guard let secrets = Secrets.fixtureForTesting(service: service) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }
    let unrelatedKey = "synthetic-unrelated-key-\(UUID().uuidString)"
    let fixtureKey = "synthetic-fixture-key-\(UUID().uuidString)"

    let unrelatedSave = await editOutcome(from: secrets.credentials, .save(.cleanup, unrelatedKey))
    let begin = await fixtureObservation(from: secrets, .begin)
    let save = await editOutcome(from: secrets.credentials, .save(.jev, fixtureKey))
    let owned = await fixtureObservation(from: secrets, .inspect)
    let end = await fixtureObservation(from: secrets, .end)
    let fresh = Secrets(.keychain(service: service))
    let fixtureItemIsGone = fresh.lookup(.jev) == nil
    let unrelatedItemSurvived = fresh.lookup(.cleanup) == unrelatedKey
    let cleanup = await editOutcome(from: fresh.credentials, .remove(.cleanup))
    let unrelatedItemWasRemoved = Secrets(.keychain(service: service)).lookup(.cleanup) == nil

    #expect(unrelatedSave == .saved)
    #expect(begin.phase == .reserved)
    #expect(save == .saved)
    #expect(owned.phase == .owned)
    #expect(owned.item == .present)
    #expect(end.phase == .idle)
    #expect(fixtureItemIsGone)
    #expect(unrelatedItemSurvived)
    #expect(cleanup == .removed)
    #expect(unrelatedItemWasRemoved)
}

@Test func realThrowawayDuplicateAddPreservesTheExistingCredential() async {
    let service = fixtureService()
    guard let secrets = Secrets.fixtureForTesting(service: service) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }
    let existingKey = "synthetic-existing-key-\(UUID().uuidString)"
    let attemptedKey = "synthetic-fixture-key-\(UUID().uuidString)"

    let initialSave = await editOutcome(from: secrets.credentials, .save(.jev, existingKey))
    let begin = await fixtureObservation(from: secrets, .begin)
    let attemptedSave = await editOutcome(from: secrets.credentials, .save(.jev, attemptedKey))
    let refused = await fixtureObservation(from: secrets, .inspect)
    let end = await fixtureObservation(from: secrets, .end)
    let fresh = Secrets(.keychain(service: service))
    let existingValueSurvived = fresh.lookup(.jev) == existingKey
    let removed = await editOutcome(from: fresh.credentials, .remove(.jev))
    let itemWasRemoved = Secrets(.keychain(service: service)).lookup(.jev) == nil

    #expect(initialSave == .saved)
    #expect(begin.phase == .reserved)
    #expect(attemptedSave == .refused)
    #expect(refused.phase == .refused)
    #expect(refused.cache == .available)
    #expect(end.phase == .idle)
    #expect(existingValueSurvived)
    #expect(removed == .removed)
    #expect(itemWasRemoved)
}

@Test func realThrowawayFixtureReplacementAndRemoveUseTheOwnedReference() async {
    let service = fixtureService()
    guard let secrets = Secrets.fixtureForTesting(service: service) else {
        Issue.record("A UUID-scoped fixture service should be accepted")
        return
    }
    let unrelated = "synthetic-unrelated-fixture-item"
    let unrelatedSave = await editOutcome(from: secrets.credentials, .save(.cleanup, unrelated))
    _ = await fixtureObservation(from: secrets, .begin)
    let created = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-first-fixture-value"))
    let replaced = await editOutcome(from: secrets.credentials, .save(.jev, "synthetic-second-fixture-value"))
    let inspected = await fixtureObservation(from: secrets, .inspect)
    let removed = await editOutcome(from: secrets.credentials, .remove(.jev))
    let ended = await fixtureObservation(from: secrets, .end)
    let fresh = Secrets(.keychain(service: service))
    let fixtureIsGone = fresh.lookup(.jev) == nil
    let unrelatedSurvived = fresh.lookup(.cleanup) == unrelated
    let cleanup = await editOutcome(from: fresh.credentials, .remove(.cleanup))
    #expect(unrelatedSave == .saved)
    #expect(created == .saved)
    #expect(replaced == .saved)
    #expect(inspected.item == .present)
    #expect(removed == .removed)
    #expect(ended.phase == .idle)
    #expect(fixtureIsGone)
    #expect(unrelatedSurvived)
    #expect(cleanup == .removed)
}

#endif
