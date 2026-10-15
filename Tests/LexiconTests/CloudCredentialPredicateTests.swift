import Testing
@testable import LexiconDomain

private let credentialIDsForEval: [CredentialID] =
    CloudModel.allCases.map(CredentialID.speech) + [.cleanup, .jev]

@Test func anEvalAllowsOnlyItsSelectedSpeechCredential() {
    for selectedModel in CloudModel.allCases {
        let use = CloudUse.eval(selectedModel)

        for credential in credentialIDsForEval {
            #expect(use.allowsCredential(credential) == (credential == .speech(selectedModel)))
        }
    }
}
