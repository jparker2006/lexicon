public import Foundation
import Network
import Synchronization
import LexiconDomain

/// Everything between the speech engine and a cloud provider's server: which
/// adapter speaks for a model, how a socket opens, and whether the network is up.
/// The app and `lexicon-eval` use `.network`; tests build a scripted link whose
/// sockets replay recorded server messages (no keys, no network).
public struct CloudLink: Sendable {
    let adapter: @Sendable (CloudModel) -> any StreamingProvider
    /// Opens a socket for a request built with a key from `CloudAccess`. Nothing
    /// else in Transcription opens a connection.
    let connect: @Sendable (URLRequest) async throws -> any CloudSocket
    let path: NetworkPath

    /// Real providers over URLSession WebSockets, reachability from NWPathMonitor.
    /// One path monitor for the process.
    public static let network = CloudLink(adapter: provider(for:), connect: WebSocket.open, path: .system)
}

/// One open connection to a provider. Recorded server messages replace it in tests.
protocol CloudSocket: Sendable {
    func send(_ message: ProviderMessage) async throws
    /// The next server message; nil once the server closed the socket cleanly.
    func receive() async throws -> ProviderMessage?
    /// Idempotent. A pending `receive` returns or throws at once.
    func close()
}

/// `URLSessionWebSocketTask`. Messages sent before the handshake completes are
/// queued by URLSession, so audio captured while TLS opens is not lost.
final class WebSocket: CloudSocket {
    let task: URLSessionWebSocketTask

    private init(task: URLSessionWebSocketTask) { self.task = task }

    static func open(_ request: URLRequest) async throws -> any CloudSocket {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return WebSocket(task: task)
    }

    func send(_ message: ProviderMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .binary(let data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> ProviderMessage? {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: return .text("")
            }
        } catch {
            if task.closeCode == .normalClosure { return nil }
            throw error
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

/// Whether the network is up, now and as it changes. Watching the path sends
/// nothing, so it runs in Private mode too.
final class NetworkPath: Sendable {
    private struct State {
        var isUp: Bool
        var watchers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let state: Mutex<State>
    /// Held for the life of the path, so its updates keep coming.
    private let monitor: NWPathMonitor?

    init(isUp: Bool) {
        state = Mutex(State(isUp: isUp))
        monitor = nil
    }

    /// Up until NWPathMonitor's first answer (a few ms after launch), so the first
    /// Dictation never skips the cloud for a path that was never checked.
    static let system: NetworkPath = {
        let monitor = NWPathMonitor()
        let path = NetworkPath(isUp: true, monitor: monitor)
        monitor.pathUpdateHandler = { [path] update in path.update(isUp: update.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "Lexicon.NetworkPath"))
        return path
    }()

    private init(isUp: Bool, monitor: NWPathMonitor) {
        state = Mutex(State(isUp: isUp))
        self.monitor = monitor
    }

    var isUp: Bool { state.withLock { $0.isUp } }

    /// The current value, then every change.
    func changes() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.watchers.removeValue(forKey: id) } }
        state.withLock { state in
            state.watchers[id] = continuation
            continuation.yield(state.isUp)
        }
        return stream
    }

    func update(isUp: Bool) {
        state.withLock { state in
            guard state.isUp != isUp else { return }
            state.isUp = isUp
            for watcher in state.watchers.values { watcher.yield(isUp) }
        }
    }
}
