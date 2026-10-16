import Synchronization
import Testing
import LexiconDomain

private let syntheticCredentials: [CredentialID] =
    CloudModel.allCases.map(CredentialID.speech) + [.cleanup, .jev]

private let syntheticKeys: @Sendable (CredentialID) -> String? = {
    "synthetic-" + $0.account
}

private let cloudUsesThatAllowEveryCredential: [CloudUse] = [
    .app(.unknown),
    .modelInstall,
]

private final class LookupObservations: Sendable {
    private let state = Mutex<[CredentialID]>([])

    func record(_ id: CredentialID) {
        state.withLock { $0.append(id) }
    }

    var credentials: [CredentialID] {
        state.withLock { $0 }
    }
}

private struct WeakCloudAccess {
    weak var value: CloudAccess?
}

private final class CloudAccessReference: Sendable {
    private let state = Mutex(WeakCloudAccess())

    func set(_ access: CloudAccess) {
        state.withLock { $0.value = access }
    }

    func revoke(_ reason: AccessRevoked) {
        state.withLock { $0.value }?.revoke(reason)
    }
}

private func accessRevokingDuringLookup(
    for use: CloudUse,
    reference: CloudAccessReference,
    observations: LookupObservations
) throws -> CloudAccess {
    let keys: @Sendable (CredentialID) -> String? = { id in
        observations.record(id)
        reference.revoke(.secretFound)
        return "synthetic-" + id.account
    }
    let access = try #require(CloudAccess.granted(by: .defaults, for: use, keys: keys))
    reference.set(access)
    return access
}

@Test func appAndModelInstallCanReadEveryCredentialWithBothKeyMethods() throws {
    for use in cloudUsesThatAllowEveryCredential {
        let access = try #require(CloudAccess.granted(by: .defaults, for: use, keys: syntheticKeys))

        for id in syntheticCredentials {
            let expected = "synthetic-" + id.account
            #expect(access.key(id) == expected)
            #expect(access.key(id, sending: "Ordinary synthetic test text.") == expected)
        }
    }
}

@Test func revocationBeforeLookupSkipsEveryCredentialForAppAndModelInstall() throws {
    for use in cloudUsesThatAllowEveryCredential {
        let observations = LookupObservations()
        let keys: @Sendable (CredentialID) -> String? = { id in
            observations.record(id)
            return "synthetic-" + id.account
        }
        let access = try #require(CloudAccess.granted(by: .defaults, for: use, keys: keys))
        access.revoke(.privateModeOn)

        for id in syntheticCredentials {
            #expect(access.key(id) == nil)
            #expect(access.key(id, sending: "Ordinary synthetic test text.") == nil)
        }
        #expect(observations.credentials.isEmpty)
    }
}

@Test func revocationDuringEachLookupDiscardsTheSyntheticCredential() throws {
    let keyCalls: [@Sendable (CloudAccess, CredentialID) -> String?] = [
        { access, id in access.key(id) },
        { access, id in access.key(id, sending: "Ordinary synthetic test text.") },
    ]

    for use in cloudUsesThatAllowEveryCredential {
        for id in syntheticCredentials {
            for keyCall in keyCalls {
                let observations = LookupObservations()
                let reference = CloudAccessReference()
                let access = try accessRevokingDuringLookup(
                    for: use,
                    reference: reference,
                    observations: observations
                )

                #expect(keyCall(access, id) == nil)
                #expect(access.revoked == .secretFound)
                #expect(observations.credentials == [id])
            }
        }
    }
}
