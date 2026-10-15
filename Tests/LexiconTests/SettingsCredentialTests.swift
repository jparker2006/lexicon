import Foundation
import Synchronization
import Testing
@testable import AudioCapture
@testable import LexiconCore
import Cleanup
import History
import LexiconDomain
@testable import Transcription
import WordStore

private func settingsCredentialService() -> String {
    "dev.jparker.lexicon.settings-tests.\(UUID().uuidString)"
}

private func outcome(
    from command: CredentialCommand,
    for edit: CredentialEdit
) async -> CredentialOutcome {
    await withCheckedContinuation { continuation in
        command(edit) { result in continuation.resume(returning: result) }
    }
}

private final class KeyMatchReceipt: Sendable {
    private let matches = Mutex<[Bool]>([])
    private let expectedKeys: [String]

    init(expectedKeys: [String]) { self.expectedKeys = expectedKeys }

    func link(clock: TestClock) -> CloudLink {
        let expectedKeys = self.expectedKeys
        let matches = self.matches
        CloudLink(
            adapter: { _ in FakeProvider() },
            connect: { request in
                matches.withLock { observations in
                    let index = observations.count
                    let matched = expectedKeys.indices.contains(index)
                        && request.value(forHTTPHeaderField: "Authorization") == expectedKeys[index]
                    observations.append(matched)
                }
                return DelayedFinalSocket(clock: clock)
            },
            path: NetworkPath(isUp: true)
        )
    }

    var connectionCount: Int { matches.withLock { $0.count } }
    var allObservedKeysMatched: Bool { matches.withLock { $0.allSatisfy { $0 } } }
}

private final class DelayedFinalSocket: CloudSocket {
    private let clock: TestClock
    private let messages: AsyncThrowingStream<ProviderMessage, any Error>
    private let continuation: AsyncThrowingStream<ProviderMessage, any Error>.Continuation

    init(clock: TestClock) {
        self.clock = clock
        (messages, continuation) = AsyncThrowingStream<ProviderMessage, any Error>.makeStream()
    }

    func send(_ message: ProviderMessage) async throws {
        guard case .text("finalize") = message else { return }
        let due = clock.now.advanced(by: .milliseconds(100))
        let clock = self.clock
        let continuation = self.continuation
        Task {
            do { try await clock.sleep(until: due, tolerance: nil) } catch { return }
            continuation.yield(.text("final:credential command used the same owner"))
            continuation.yield(.text("end"))
            continuation.finish()
        }
    }

    func receive() async throws -> ProviderMessage? {
        for try await message in messages { return message }
        return nil
    }

    func close() { continuation.finish() }
}

private func cloudDictation(
    on conductor: Conductor<HeadlessDestination>,
    file: URL,
    clock: TestClock,
    replyAt: Duration,
    raceDeadline: Duration
) async -> DictationResult {
    let running = Task { await conductor.dictate(file: file, pace: .asFastAsPossible) }
    await clock.waitForSleep(endingAt: replyAt)
    await clock.waitForSleep(endingAt: raceDeadline)
    await clock.advance(by: .milliseconds(100))
    return await running.value
}

@Test(.timeLimit(.minutes(1)))
func oneConductorUsesCredentialCommandUpdatesWithoutRestart() async throws {
    let service = settingsCredentialService()
    let secrets = Secrets(.keychain(service: service))
    let id = CredentialID.speech(.museVoice)
    let credentialCommand = secrets.credentials
    let syntheticKey = "synthetic-settings-key-\(UUID().uuidString)"
    let replacementKey = "synthetic-settings-replacement-\(UUID().uuidString)"

    let initialLookupWasMissing = secrets.lookup(id) == nil
    #expect(initialLookupWasMissing)

    var preferences = Preferences.defaults
    preferences.cloudModel = .museVoice
    let clock = TestClock()
    let receipt = KeyMatchReceipt(expectedKeys: [syntheticKey, replacementKey])
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let lexicon = try Lexicon(paths: paths)
    let conductor = Conductor(
        recorder: Recorder(),
        speech: SpeechEngine(local: ScriptedTranscriber(text: "local fallback"),
                              cloud: receipt.link(clock: clock), clock: clock),
        cleanup: Cleanup(), lexicon: lexicon, history: history,
        destination: HeadlessDestination(), preferences: PreferencesStore(fixed: preferences),
        secrets: secrets, keyboard: nil, fixes: nil, jev: nil
    )
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())

    let beforeSave = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    #expect(beforeSave.model == .local(.parakeetUnified))
    let noConnectorBeforeSave = receipt.connectionCount == 0
    #expect(noConnectorBeforeSave)

    let save = await outcome(from: credentialCommand, for: .save(id, syntheticKey))
    #expect(save == .saved)
    let savedValueIsInTheConductorCache = secrets.lookup(id) == syntheticKey
    #expect(savedValueIsInTheConductorCache)

    do {
        let result = await cloudDictation(on: conductor, file: wav, clock: clock,
                                          replyAt: .milliseconds(100), raceDeadline: .milliseconds(300))
        await history.flush()

        #expect(result.model == .cloud(.museVoice))
        let firstConnectionConsumedExpectedKey = receipt.connectionCount == 1 && receipt.allObservedKeysMatched
        #expect(firstConnectionConsumedExpectedKey)

        let replace = await outcome(from: credentialCommand, for: .save(id, replacementKey))
        #expect(replace == .saved)
        let replacementReachedTheSameCache = secrets.lookup(id) == replacementKey
        #expect(replacementReachedTheSameCache)

        let replacementResult = await cloudDictation(on: conductor, file: wav, clock: clock,
                                                     replyAt: .milliseconds(200), raceDeadline: .milliseconds(400))
        #expect(replacementResult.model == .cloud(.museVoice))
        let replacementConnectionConsumedExpectedKey = receipt.connectionCount == 2 && receipt.allObservedKeysMatched
        #expect(replacementConnectionConsumedExpectedKey)
    } catch {
        _ = await outcome(from: credentialCommand, for: .remove(id))
        throw error
    }

    let remove = await outcome(from: credentialCommand, for: .remove(id))
    #expect(remove == .removed)
    let removalReachedTheSameCache = secrets.lookup(id) == nil
    #expect(removalReachedTheSameCache)

    let afterRemove = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    #expect(afterRemove.model == .local(.parakeetUnified))
    let removalPreventedAnotherConnection = receipt.connectionCount == 2
    #expect(removalPreventedAnotherConnection)

    await history.flush()
}

@Test
func credentialCommandsKeepEmptySaveDistinctAndEnvironmentReadOnly() async {
    let service = settingsCredentialService()
    let secrets = Secrets(.keychain(service: service))
    let command = secrets.credentials
    let id = CredentialID.speech(.museVoice)
    let submittedKey = "synthetic-empty-save-key-\(UUID().uuidString)"
    let preferences = PreferencesStore(fixed: .defaults)
    let defaultsBefore = preferences.snapshot()
    let speechModelsBefore = CloudModel.allCases

    let canonicalIDs = CloudModel.allCases.map(CredentialID.speech) + [.cleanup, .jev]
    let canonicalAccounts = canonicalIDs.map(\.account)
    let canonicalAccountsAreUnique = Set(canonicalAccounts).count == canonicalAccounts.count
    #expect(canonicalAccountsAreUnique)

    for canonicalID in canonicalIDs {
        let availability = await outcome(from: command, for: .availability(canonicalID))
        #expect(availability == .availability(.missing))
    }

    let saved = await outcome(from: command, for: .save(id, submittedKey))
    #expect(saved == .saved)
    let emptySave = await outcome(from: command, for: .save(id, " \n\t "))
    #expect(emptySave == .emptyEntry)
    let emptySavePreservedCachedKey = secrets.lookup(id) == submittedKey
    #expect(emptySavePreservedCachedKey)

    let preferencesStayedTheSame = preferences.snapshot() == defaultsBefore
    #expect(preferencesStayedTheSame)
    let speechModelListStayedTheSame = CloudModel.allCases == speechModelsBefore
    #expect(speechModelListStayedTheSame)

    let environmentCommand = Secrets(.environment).credentials
    let environmentAvailability = await outcome(from: environmentCommand, for: .availability(id))
    #expect(environmentAvailability == .availability(.unavailable))
    let environmentSave = await outcome(from: environmentCommand, for: .save(id, submittedKey))
    #expect(environmentSave == .unavailable)
    let environmentRemove = await outcome(from: environmentCommand, for: .remove(id))
    #expect(environmentRemove == .unavailable)

    let removed = await outcome(from: command, for: .remove(id))
    #expect(removed == .removed)
}
