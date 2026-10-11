#if DEBUG
import Foundation
import Synchronization
import Testing
import LexiconDomain
@testable import TestHooks

// The test-hook wire (#45), both ends in one process. The live half (the dev
// app answering, the Accessibility harness) is checked with `scripts/harness.sh check`.

private let status = TestHookStatus(bundleID: AppPaths.devBundleID, version: "0.1 (1, abc)", pid: 42,
                                    accessibility: true, microphone: "granted")

@Test func aCommandSentToTheRunningServerGetsItsReply() async throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    let server = try TestHookServer(channel: channel) { command in
        command == .status ? .status(status) : .failed("unexpected \(command)")
    }
    let reply = try await channel.send(.status, timeout: .seconds(10))
    #expect(reply == .status(status))
    #expect(try leftovers(channel).isEmpty)
    withExtendedLifetime(server) {}
}

@Test func withNobodyListeningSendGivesUpAndTakesItsRequestBack() async throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    await #expect(throws: TestHookError.noReply) {
        try await channel.send(.status, timeout: .milliseconds(50))
    }
    #expect(try leftovers(channel).isEmpty)
}

@Test func aRequestWaitingFromBeforeLaunchIsAnsweredWhenTheServerStarts() async throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    let sent = Task { try await channel.send(.status, timeout: .seconds(10)) }
    try await waitUntil { requestCount(channel) == 1 }
    let server = try TestHookServer(channel: channel) { _ in .status(status) }
    #expect(try await sent.value == .status(status))
    withExtendedLifetime(server) {}
}

@Test func aStaleRequestIsDroppedUnanswered() async throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    let request = try post(Data(#"{"dictate":{"wav":"/tmp/old.wav"}}"#.utf8), to: channel)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                          ofItemAtPath: request.path)
    let handled = Handled()
    let server = try TestHookServer(channel: channel) { command in
        handled.append(command)
        return .status(status)
    }
    // A handler for the stale request would have been queued before this one.
    #expect(try await channel.send(.status, timeout: .seconds(10)) == .status(status))
    #expect(handled.commands == [.status])
    #expect(try leftovers(channel).isEmpty)
    withExtendedLifetime(server) {}
}

@Test func aMalformedRequestGetsAFailedReply() throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    let request = try post(Data("not json".utf8), to: channel)
    let server = try TestHookServer(channel: channel) { _ in .status(status) }
    let reply = channel.replies.appending(path: request.lastPathComponent)
    #expect(try JSONDecoder().decode(TestHookReply.self, from: Data(contentsOf: reply)) == .failed("not a test hook command"))
    #expect(requestCount(channel) == 0)
    withExtendedLifetime(server) {}
}

// MARK: - Helpers

private func post(_ data: Data, to channel: TestHookChannel) throws -> URL {
    try FileManager.default.createDirectory(at: channel.requests, withIntermediateDirectories: true)
    let url = channel.requests.appending(path: "\(UUID().uuidString).json")
    try data.write(to: url)
    return url
}

private func requestCount(_ channel: TestHookChannel) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: channel.requests.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.count
}

/// Every file left in either folder.
private func leftovers(_ channel: TestHookChannel) throws -> [String] {
    try [channel.requests, channel.replies].flatMap { folder in
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }
}

private func waitUntil(_ condition: () throws -> Bool) async throws {
    for _ in 0..<2_000 where try !condition() { try await Task.sleep(for: .milliseconds(5)) }
    try #require(try condition())
}

private final class Handled: Sendable {
    private let list = Mutex<[TestHookCommand]>([])
    func append(_ command: TestHookCommand) { list.withLock { $0.append(command) } }
    var commands: [TestHookCommand] { list.withLock { $0 } }
}
#endif
