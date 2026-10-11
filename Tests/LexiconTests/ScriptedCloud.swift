import Foundation
import Synchronization
import LexiconDomain
@testable import Transcription

// A scripted fake cloud provider (#66): recorded server messages replace the
// socket, and every server reply is timed on the test's clock. No keys, no
// network: the link's sockets never leave the process.

/// One server message the scripted socket sends, and when.
struct Reply: Sendable {
    enum Cue: Sendable {
        /// Once the client has sent this many audio frames (while Jake talks).
        case afterFrames(Int)
        /// This long after the client's finalize, on the test clock.
        case afterFinalize(Duration)
    }

    enum Message: Sendable {
        case partial(String)
        case final(String)
        /// The provider ends the session: no more finals.
        case end
        case error(String)
        /// The connection drops (receive throws).
        case drop
    }

    let cue: Cue
    let message: Message

    static func partial(_ text: String, afterFrames frames: Int) -> Reply { Reply(cue: .afterFrames(frames), message: .partial(text)) }
    static func final(_ text: String, afterFrames frames: Int) -> Reply { Reply(cue: .afterFrames(frames), message: .final(text)) }

    /// The usual answer to finalize: the last final, then the end of the session.
    static func finalText(_ text: String, after delay: Duration) -> [Reply] {
        [Reply(cue: .afterFinalize(delay), message: .final(text)), Reply(cue: .afterFinalize(delay), message: .end)]
    }
}

/// A provider wire format for tests: text frames "partial:", "final:", "end",
/// "error:"; audio as binary frames.
struct FakeProvider: StreamingProvider {
    func connectRequest(key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://fake-provider.invalid/asr")!)
        request.setValue(key, forHTTPHeaderField: "Authorization")
        return request
    }

    func sessionStart(terms: [Term]) -> ProviderMessage? {
        .text("start:" + terms.map(\.text).joined(separator: ","))
    }

    func audio(_ chunk: PCMChunk) -> ProviderMessage {
        .binary(chunk.samples.withUnsafeBytes { Data($0) })
    }

    func finalize() -> ProviderMessage { .text("finalize") }

    func parse(_ message: ProviderMessage) -> ProviderEvent {
        guard case .text(let text) = message else { return .ignore }
        if text == "end" { return .sessionEnded }
        if let rest = text.dropPrefix("partial:") { return .partial(rest) }
        if let rest = text.dropPrefix("final:") { return .final(rest) }
        if let rest = text.dropPrefix("error:") { return .error(rest) }
        return .ignore
    }
}

/// What the client did on the scripted socket, for tests to check.
struct SocketLog: Sendable {
    var connects = 0
    /// Authorization header of each connect.
    var keys: [String] = []
    var sessionStarts: [String] = []
    var audioFrames = 0
    var finalized = false
    var closed = false
}

/// The fake cloud: a `CloudLink` whose sockets replay `script`.
final class ScriptedCloud: Sendable {
    let clock: TestClock
    let script: [Reply]
    let connectError: (any Error)?
    let path: NetworkPath
    private let state = Mutex(State())

    private struct State {
        var log = SocketLog()
        var waiters: [(check: @Sendable (SocketLog) -> Bool, wake: CheckedContinuation<Void, Never>)] = []
    }

    /// - `connectError`: opening the socket fails (a dead network or a refused handshake).
    /// - `networkUp`: false means NWPathMonitor reports no path at fn-down.
    init(clock: TestClock, script: [Reply], connectError: (any Error)? = nil, networkUp: Bool = true) {
        self.clock = clock
        self.script = script
        self.connectError = connectError
        path = NetworkPath(isUp: networkUp)
    }

    var link: CloudLink {
        CloudLink(adapter: { _ in FakeProvider() }, connect: { [self] request in try open(request) }, path: path)
    }

    var log: SocketLog { state.withLock { $0.log } }

    /// Returns once `condition` holds for the socket log (an explicit signal, not a sleep).
    func wait(until condition: @escaping @Sendable (SocketLog) -> Bool) async {
        await withCheckedContinuation { wake in
            let now = state.withLock { state -> Bool in
                if condition(state.log) { return true }
                state.waiters.append((condition, wake))
                return false
            }
            if now { wake.resume() }
        }
    }

    fileprivate func update(_ change: (inout SocketLog) -> Void) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            change(&state.log)
            let log = state.log
            let (ready, waiting) = (state.waiters.filter { $0.check(log) }, state.waiters.filter { !$0.check(log) })
            state.waiters = waiting
            return ready.map(\.wake)
        }
        for wake in ready { wake.resume() }
    }

    private func open(_ request: URLRequest) throws -> any CloudSocket {
        update {
            $0.connects += 1
            $0.keys.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        }
        if let connectError { throw connectError }
        return ScriptedSocket(cloud: self)
    }
}

private struct ConnectionLost: Error {}

/// One scripted connection. Replies due after N frames are queued as the frames
/// arrive; replies due after finalize sleep on the test clock first.
private final class ScriptedSocket: CloudSocket {
    let cloud: ScriptedCloud
    private let inbox: AsyncThrowingStream<String, any Error>
    private let deliver: AsyncThrowingStream<String, any Error>.Continuation
    private let frames = Mutex(0)
    private let timers = Mutex<[Task<Void, Never>]>([])

    init(cloud: ScriptedCloud) {
        self.cloud = cloud
        (inbox, deliver) = AsyncThrowingStream<String, any Error>.makeStream()
    }

    func send(_ message: ProviderMessage) async throws {
        guard !cloud.log.closed else { throw ConnectionLost() }
        switch message {
        case .binary:
            let count = frames.withLock { frames in
                frames += 1
                return frames
            }
            cloud.update { $0.audioFrames += 1 }
            for reply in cloud.script {
                if case .afterFrames(count) = reply.cue { post(reply.message) }
            }
        case .text("finalize"):
            cloud.update { $0.finalized = true }
            // One timer, replies in script order: a final and the session end due
            // at the same moment always arrive final first.
            let clock = cloud.clock
            let start = clock.now
            let due = cloud.script.compactMap { reply -> (Duration, Reply.Message)? in
                guard case .afterFinalize(let delay) = reply.cue else { return nil }
                return (delay, reply.message)
            }
            let timer = Task { [self] in
                for (delay, message) in due {
                    do { try await clock.sleep(until: start.advanced(by: delay), tolerance: nil) } catch { return }
                    post(message)
                }
            }
            timers.withLock { $0.append(timer) }
            if cloud.log.closed { timer.cancel() }  // closed while this finalize was going out
        case .text(let text):
            if let terms = text.dropPrefix("start:") { cloud.update { $0.sessionStarts.append(terms) } }
        }
    }

    func receive() async throws -> ProviderMessage? {
        for try await message in inbox { return .text(message) }
        return nil
    }

    func close() {
        cloud.update { $0.closed = true }
        for timer in timers.withLock({ $0 }) { timer.cancel() }
        deliver.finish(throwing: CancellationError())
    }

    private func post(_ message: Reply.Message) {
        switch message {
        case .partial(let text): deliver.yield("partial:" + text)
        case .final(let text): deliver.yield("final:" + text)
        case .end: deliver.yield("end")
        case .error(let text): deliver.yield("error:" + text)
        case .drop: deliver.finish(throwing: ConnectionLost())
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
