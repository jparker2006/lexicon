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

/// How long a test waits for a reply that takes milliseconds. Generous on
/// purpose: the server answers from a task, and a loaded CI runner can leave
/// tasks waiting many seconds for a thread. The wait ends on the reply,
/// not on this limit, so a pass never costs it.
private let replyLimit = Duration.seconds(120)

@Test func aCommandSentToTheRunningServerGetsItsReply() async throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    let server = try TestHookServer(channel: channel) { command in
        command == .status ? .status(status) : .failed("unexpected \(command)")
    }
    let reply = try await channel.send(.status, timeout: replyLimit)
    #expect(reply == .status(status))
    #expect(leftovers(channel).isEmpty)
    withExtendedLifetime(server) {}
}

@Test func manyRequestsAtOnceEachGetTheirOwnReply() async throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    // Echoes each request's text, so a reply can be matched to its request.
    let server = try TestHookServer(channel: channel) { command in
        guard case .insert(let text, _) = command else { return .failed("unexpected \(command)") }
        return .failed(text)
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for n in 0..<50 {
            group.addTask {
                let reply = try await channel.send(.insert(text: "\(n)", delay: 0), timeout: replyLimit)
                #expect(reply == .failed("\(n)"))
            }
        }
        try await group.waitForAll()
    }
    #expect(leftovers(channel).isEmpty)
    withExtendedLifetime(server) {}
}

@Test func withNobodyListeningSendGivesUpAndTakesItsRequestBack() async throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    await #expect(throws: TestHookError.noReply) {
        try await channel.send(.status, timeout: .milliseconds(50))
    }
    #expect(leftovers(channel).isEmpty)
}

@Test(.timeLimit(.minutes(1))) func aCancelledSenderStopsWaitingAndTakesItsRequestBack() async throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    let sent = Task {
        // Cancelled before the wait starts: the hardest case, so this needs no timing.
        withUnsafeCurrentTask { $0?.cancel() }
        return try await channel.send(.status, timeout: replyLimit)
    }
    await #expect(throws: TestHookError.noReply) { try await sent.value }
    #expect(leftovers(channel).isEmpty)
}

@Test func aReplyThatLandedInTimeIsReadHoweverLateTheSenderWakes() async throws {
    // Under load the sender can wake after its deadline; a reply that landed by
    // then still counts. A zero timeout is a sender whose deadline has passed
    // with the reply already there.
    let channel = TestHookChannel(paths: AppPaths.temporary())
    let name = try channel.post(.status)
    try answer(name, with: .status(status), on: channel)
    #expect(try await channel.reply(to: name, timeout: .zero) == .status(status))
    #expect(leftovers(channel).isEmpty)
}

@Test func aRequestWaitingFromBeforeLaunchIsAnsweredWhenTheServerStarts() async throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    let name = try channel.post(.status)
    let server = try TestHookServer(channel: channel) { _ in .status(status) }
    #expect(try await channel.reply(to: name, timeout: replyLimit) == .status(status))
    #expect(leftovers(channel).isEmpty)
    withExtendedLifetime(server) {}
}

@Test func aStaleRequestIsDroppedUnanswered() async throws {
    let channel = TestHookChannel(paths: AppPaths.temporary())
    let request = try post(Data(#"{"dictate":{"wav":"/tmp/old.wav"}}"#.utf8), to: channel)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * TestHookChannel.staleAfter)],
                                          ofItemAtPath: request.path)
    let handled = Handled()
    let server = try TestHookServer(channel: channel) { command in
        handled.append(command)
        return .status(status)
    }
    // The server looks at waiting requests before its init returns.
    #expect(leftovers(channel).isEmpty)
    // A handler for the stale request would have been started before this one.
    #expect(try await channel.send(.status, timeout: replyLimit) == .status(status))
    #expect(handled.commands == [.status])
    #expect(leftovers(channel).isEmpty)
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

/// What the server does for one request: takes it and writes its reply.
private func answer(_ name: String, with reply: TestHookReply, on channel: TestHookChannel) throws {
    try FileManager.default.removeItem(at: channel.requests.appending(path: name))
    try FileManager.default.createDirectory(at: channel.replies, withIntermediateDirectories: true)
    try JSONEncoder().encode(reply).write(to: channel.replies.appending(path: name), options: .atomic)
}

private func requestCount(_ channel: TestHookChannel) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: channel.requests.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.count
}

/// Every file left in either folder.
private func leftovers(_ channel: TestHookChannel) -> [String] {
    [channel.requests, channel.replies].flatMap { folder in
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }
}

private final class Handled: Sendable {
    private let list = Mutex<[TestHookCommand]>([])
    func append(_ command: TestHookCommand) { list.withLock { $0.append(command) } }
    var commands: [TestHookCommand] { list.withLock { $0 } }
}
#endif
