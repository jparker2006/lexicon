import Foundation
import Synchronization
@testable import Transcription

/// The synthetic Muse frames used by the lifecycle, queue, and rollover tests.
enum MuseServerFrame {
    static let acknowledgement = ProviderMessage.text(#"{"sessionId":"synthetic-session"}"#)

    static func transcript(_ text: String, final: Bool = true, audioProcessedMs: Int = 80) -> ProviderMessage {
        json(["type": "transcript", "transcript": text, "final": final,
              "audioProcessedMs": audioProcessedMs])
    }

    static func error(_ message: String) -> ProviderMessage {
        json(["type": "error", "message": message, "sessionId": "synthetic-session"])
    }

    private static func json(_ value: [String: Any]) -> ProviderMessage {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return .text(String(decoding: data, as: UTF8.self))
    }
}

/// A signal-controlled barrier for connect and send races. `pause()` does not
/// return until `release()` is called or its owning task is cancelled.
final class MuseBarrier: Sendable {
    private struct Arrival {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var released = false
        var entered = 0
        var blocked: [UUID: CheckedContinuation<Void, Never>] = [:]
        var arrivals: [UUID: Arrival] = [:]
    }

    private let state = Mutex(State())

    var enteredCount: Int { state.withLock { $0.entered } }

    func pause() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    state.entered += 1
                    let arrivals = state.arrivals.filter { $0.value.count <= state.entered }
                    for key in arrivals.keys { state.arrivals.removeValue(forKey: key) }
                    if state.released || Task.isCancelled { return (true, arrivals.values.map(\.continuation)) }
                    state.blocked[id] = continuation
                    return (false, arrivals.values.map(\.continuation))
                }
                for arrival in result.1 { arrival.resume() }
                if result.0 { continuation.resume() }
            }
        } onCancel: {
            self.state.withLock { $0.blocked.removeValue(forKey: id) }?.resume()
        }
    }

    func waitUntilEntered(_ count: Int = 1) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Bool in
                    if state.entered >= count || Task.isCancelled { return true }
                    state.arrivals[id] = Arrival(count: count, continuation: continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            self.state.withLock { $0.arrivals.removeValue(forKey: id) }?.continuation.resume()
        }
    }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.blocked = [:] }
            return Array(state.blocked.values)
        }
        for waiter in waiters { waiter.resume() }
    }
}

struct MuseSocketLog: Sendable {
    var sendCalls = 0
    var messages: [ProviderMessage] = []
    var pendingReceives = 0
    var serverFinishedNormally = false
    var serverDropped = false
    var clientCloseCalls = 0

    var textMessages: [String] {
        messages.compactMap { message in
            guard case .text(let text) = message else { return nil }
            return text
        }
    }

    var binaryMessages: [Data] {
        messages.compactMap { message in
            guard case .binary(let data) = message else { return nil }
            return data
        }
    }

    var endStreamSent: Bool {
        textMessages.contains { text in
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["type"] as? String == "endStream"
        }
    }
}

/// A fake Muse WebSocket. The test injects server frames and chooses when a
/// normal server close or a transport failure arrives.
final class MuseSocket: CloudSocket, Sendable {
    private struct Waiter {
        let id: UUID
        let check: @Sendable (MuseSocketLog) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var log = MuseSocketLog()
        var waiters: [Waiter] = []
        var binaryCount = 0
        var clientClosed = false
    }

    private let state = Mutex(State())
    private let inbox: AsyncThrowingStream<ProviderMessage, any Error>
    private let deliver: AsyncThrowingStream<ProviderMessage, any Error>.Continuation
    private let sendBarrier: MuseBarrier?
    private let audioSendBarrier: MuseBarrier?
    private let failOnBinary: Int?
    private let sendFailure: (any Error)?

    init(sendBarrier: MuseBarrier? = nil, audioSendBarrier: MuseBarrier? = nil,
         failOnBinary: Int? = nil,
         failure: (any Error)? = nil) {
        self.sendBarrier = sendBarrier
        self.audioSendBarrier = audioSendBarrier
        self.failOnBinary = failOnBinary
        sendFailure = failure
        (inbox, deliver) = AsyncThrowingStream<ProviderMessage, any Error>.makeStream()
    }

    var log: MuseSocketLog { state.withLock { $0.log } }

    func send(_ message: ProviderMessage) async throws {
        update { $0.sendCalls += 1 }
        if case .binary = message {
            await audioSendBarrier?.pause()
        } else {
            await sendBarrier?.pause()
        }
        guard !Task.isCancelled else { throw CancellationError() }

        let fails = mutate { state -> Bool in
            state.log.messages.append(message)
            guard case .binary = message else { return false }
            state.binaryCount += 1
            return state.binaryCount == failOnBinary
        }
        if fails { throw sendFailure ?? NSError(domain: "synthetic.muse", code: 1011) }
    }

    func receive() async throws -> ProviderMessage? {
        update { $0.pendingReceives += 1 }
        defer { update { $0.pendingReceives -= 1 } }
        for try await message in inbox { return message }
        return nil
    }

    func close() {
        let shouldClose = state.withLock { state -> Bool in
            guard !state.clientClosed else { return false }
            state.clientClosed = true
            state.log.clientCloseCalls += 1
            return true
        }
        if shouldClose { deliver.finish() }
        notifyWaiters()
    }

    func post(_ message: ProviderMessage) {
        deliver.yield(message)
    }

    func finishNormally() {
        update { $0.serverFinishedNormally = true }
        deliver.finish()
    }

    func drop(_ error: any Error) {
        update { $0.serverDropped = true }
        deliver.finish(throwing: error)
    }

    /// Returns when the predicate holds, or when the test's cancellation ends
    /// the wait. This keeps every socket assertion on an explicit event.
    func wait(until condition: @escaping @Sendable (MuseSocketLog) -> Bool) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let now = state.withLock { state -> Bool in
                    if condition(state.log) || Task.isCancelled { return true }
                    state.waiters.append(Waiter(id: id, check: condition, continuation: continuation))
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiter = self.state.withLock { state in
                state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0) }
            }
            waiter?.continuation.resume()
        }
    }

    private func update(_ change: (inout MuseSocketLog) -> Void) {
        mutate { state in change(&state.log) }
    }

    private func mutate<T>(_ change: (inout State) -> T) -> T {
        let (result, ready) = state.withLock { state -> (T, [CheckedContinuation<Void, Never>]) in
            let result = change(&state)
            let log = state.log
            let ready = state.waiters.filter { $0.check(log) }
            state.waiters.removeAll { $0.check(log) }
            return (result, ready.map(\.continuation))
        }
        for waiter in ready { waiter.resume() }
        return result
    }

    private func notifyWaiters() {
        update { _ in }
    }
}

final class MuseScriptedCloud: Sendable {
    struct Log: Sendable {
        var connects = 0
    }

    private struct Waiter {
        let id: UUID
        let check: @Sendable (Log) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var log = Log()
        var nextSocket = 0
        var waiters: [Waiter] = []
    }

    let sockets: [MuseSocket]
    let path: NetworkPath
    let clock: any Clock<Duration>
    let policy: CloudSession.Policy
    private let connectBarrier: MuseBarrier?
    private let state = Mutex(State())

    init(clock: any Clock<Duration>, policy: CloudSession.Policy = .init(),
         sockets: [MuseSocket], connectBarrier: MuseBarrier? = nil,
         paceAudio: Bool = false, networkUp: Bool = true) {
        self.clock = clock
        var policy = policy
        policy.paceAudio = paceAudio
        self.policy = policy
        self.sockets = sockets
        self.connectBarrier = connectBarrier
        path = NetworkPath(isUp: networkUp)
    }

    var log: Log { state.withLock { $0.log } }

    var link: CloudLink {
        CloudLink(adapter: { _ in MuseVoice() }, connect: { [self] _ in
            update { $0.connects += 1 }
            await connectBarrier?.pause()
            guard !Task.isCancelled else { throw CancellationError() }
            let socket = state.withLock { state -> MuseSocket? in
                guard state.nextSocket < sockets.count else { return nil }
                defer { state.nextSocket += 1 }
                return sockets[state.nextSocket]
            }
            guard let socket else { throw URLError(.cannotConnectToHost) }
            return socket
        }, path: path, clock: clock, policy: policy)
    }

    func wait(until condition: @escaping @Sendable (Log) -> Bool) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let now = state.withLock { state -> Bool in
                    if condition(state.log) || Task.isCancelled { return true }
                    state.waiters.append(Waiter(id: id, check: condition, continuation: continuation))
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiter = self.state.withLock { state in
                state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0) }
            }
            waiter?.continuation.resume()
        }
    }

    private func update(_ change: (inout Log) -> Void) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            change(&state.log)
            let log = state.log
            let ready = state.waiters.filter { $0.check(log) }
            state.waiters.removeAll { $0.check(log) }
            return ready.map(\.continuation)
        }
        for waiter in ready { waiter.resume() }
    }
}
