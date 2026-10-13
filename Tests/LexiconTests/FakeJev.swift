import Foundation
import Synchronization
import LexiconDomain

// A fake TypeSafe server behind URLProtocol: the real URLSession, request and
// response decoding, with no network. Fake keys only. Each fake's session tags
// its requests, so tests run in parallel without seeing each other's.

final class FakeJev: Sendable {
    struct Request: Sendable {
        let method: String?
        let url: URL?
        let headers: [String: String]
        let body: Data
    }

    /// nil: the request hangs until the client cancels it.
    typealias Reply = @Sendable (Data) -> (status: Int, body: Data)?

    static let servers = Mutex<[String: FakeJev]>([:])

    let key = "fake-jev-key-" + UUID().uuidString
    let reply: Reply
    /// Fails every POST with this instead of replying, as URLSession does.
    let failure: URLError?
    private let received = Mutex<[Request]>([])
    private let arrivals: AsyncStream<Void>.Continuation
    let arrived: AsyncStream<Void>

    init(failing failure: URLError? = nil, reply: @escaping Reply = { _ in nil }) {
        self.reply = reply
        self.failure = failure
        (arrived, arrivals) = AsyncStream<Void>.makeStream()
        Self.servers.withLock { $0[key] = self }
    }

    var requests: [Request] { received.withLock { $0 } }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeJevProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fake-Jev": key]
        return URLSession(configuration: configuration)
    }

    func access(_ preferences: Preferences = .defaults) -> CloudAccess? {
        let key = key
        return CloudAccess.granted(by: preferences, for: .app(.unknown)) { $0 == .jev ? key : nil }
    }

    func receive(_ request: Request) -> (status: Int, body: Data)? {
        received.withLock { $0.append(request) }
        arrivals.yield()
        return request.method == "HEAD" ? (405, Data()) : reply(request.body)
    }
}

/// `@unchecked Sendable`: URLProtocol is an Objective-C class URLSession drives
/// from its own queue; this subclass adds no state of its own.
final class FakeJevProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let tag = request.value(forHTTPHeaderField: "X-Fake-Jev") ?? ""
        guard let server = FakeJev.servers.withLock({ $0[tag] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let received = FakeJev.Request(method: request.httpMethod, url: request.url,
                                       headers: request.allHTTPHeaderFields ?? [:], body: bodyData())
        let answer = server.receive(received)
        if let failure = server.failure, received.method != "HEAD" {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let (status, body) = answer else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not `httpBody`.
    private func bodyData() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

func jevReply(_ probabilities: [String: Double]) -> Data {
    let json: [String: Any] = [
        "model": "jev-1.13.0",
        "answers": ["target": ["type": "choice", "choice": probabilities.max { $0.value < $1.value }!.key,
                               "probabilities": probabilities, "confidence": 0.9]],
        "usage": ["input_tokens": 300, "output_tokens": 20],
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}
