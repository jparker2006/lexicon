#if DEBUG
import Foundation
import LexiconDomain
import Testing
@testable import TestHooks

@Test func settingsFixtureGateRequiresTheDevBundleAndExactHookArgument() {
    #expect(TestHookChannel.isEnabled(bundleID: AppPaths.devBundleID, arguments: ["Lexicon Dev", "--test-hooks"]))
    #expect(!TestHookChannel.isEnabled(bundleID: "com.example.other", arguments: ["Lexicon Dev", "--test-hooks"]))
    #expect(!TestHookChannel.isEnabled(bundleID: AppPaths.devBundleID, arguments: ["Lexicon Dev"]))
    #expect(!TestHookChannel.isEnabled(bundleID: AppPaths.devBundleID, arguments: ["Lexicon Dev", "--test-hooks-extra"]))
}

@Test func settingsFixtureCommandsRoundTripAndRejectUnknownOrParameterizedCommands() throws {
    let commands: [TestHookCommand] = [
        .settingsFixtureBegin,
        .settingsFixtureInspect,
        .settingsFixtureEnd,
    ]
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for command in commands {
        let encoded = try encoder.encode(command)
        #expect(try decoder.decode(TestHookCommand.self, from: encoded) == command)

        var unknown = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let knownCase = try #require(unknown.keys.first)
        let removedCase = unknown.removeValue(forKey: knownCase)
        let encodedCase = try #require(removedCase)
        unknown["settingsFixtureUnknown"] = encodedCase
        let unknownData = try JSONSerialization.data(withJSONObject: unknown)
        #expect(throws: DecodingError.self) { try decoder.decode(TestHookCommand.self, from: unknownData) }

        var parameterized = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let caseName = try #require(parameterized.keys.first)
        parameterized[caseName] = [
            "account": "arbitrary-account",
            "service": "arbitrary-service",
            "value": "arbitrary-secret",
        ]
        let parameterizedData = try JSONSerialization.data(withJSONObject: parameterized)
        #expect(throws: DecodingError.self) { try decoder.decode(TestHookCommand.self, from: parameterizedData) }
    }
}

@Test func settingsFixtureReplyCarriesOnlyBoundedStateAndClosedEnums() throws {
    let payloads: [TestHookSettingsFixture] = [
        .init(phase: .idle, outcome: .ok, cache: .unknown, item: .none, pid: 41, fieldsAreEmpty: true),
        .init(phase: .reserved, outcome: .refused, cache: .missing, item: .none, pid: 42, fieldsAreEmpty: true),
        .init(phase: .refused, outcome: .unavailable, cache: .unknown, item: .unavailable, pid: 43, fieldsAreEmpty: false),
        .init(phase: .owned, outcome: .ok, cache: .available, item: .present, pid: 44, fieldsAreEmpty: true),
        .init(phase: .removed, outcome: .ok, cache: .missing, item: .none, pid: 45, fieldsAreEmpty: true),
        .init(phase: .stranded, outcome: .unavailable, cache: .unknown, item: .unavailable, pid: 46, fieldsAreEmpty: true),
    ]
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for payload in payloads {
        let reply = TestHookReply.settingsFixture(payload)
        let encoded = try encoder.encode(reply)
        #expect(try decoder.decode(TestHookReply.self, from: encoded) == reply)
        let wire = try #require(String(data: encoded, encoding: .utf8))
        #expect(!wire.contains("arbitrary-account"))
        #expect(!wire.contains("arbitrary-service"))
        #expect(!wire.contains("arbitrary-secret"))
        #expect(!wire.contains("reference"))
        #expect(!wire.contains("marker"))
    }
}
#endif
