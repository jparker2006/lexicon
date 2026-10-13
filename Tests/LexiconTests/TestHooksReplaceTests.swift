#if DEBUG
import Foundation
import Testing
@testable import TestHooks

// The Re-speak replace hooks (#83), as the wire carries them: each command and reply round
// trips through JSON. The live half (the field's text after a replace) is checked with
// `lexicon-harness replace-check`.

@Test func theReplaceCommandsRoundTripThroughJSON() throws {
    let commands: [TestHookCommand] = [
        .replace(word: "beta", occurrence: 2, with: "Supabase", delay: 0),
        .replaceSelection(with: "Kotlin", delay: 1.5),
    ]
    for command in commands {
        #expect(try JSONDecoder().decode(TestHookCommand.self, from: JSONEncoder().encode(command)) == command)
    }
}

@Test func theReplaceReplyRoundTripsThroughJSON() throws {
    // A reply with no bundle id (nil must survive the wire) and a refusal's rawValue as its outcome.
    let replies: [TestHookReply] = [
        .replaced(TestHookReplacement(bundleID: "com.apple.TextEdit", outcome: "replaced", readMicros: 1_200,
                                      replaceMicros: 88_000, fieldLengthBefore: 31)),
        .replaced(TestHookReplacement(bundleID: nil, outcome: "textChanged", readMicros: 0, replaceMicros: 0,
                                      fieldLengthBefore: 0)),
    ]
    for reply in replies {
        #expect(try JSONDecoder().decode(TestHookReply.self, from: JSONEncoder().encode(reply)) == reply)
    }
}
#endif
