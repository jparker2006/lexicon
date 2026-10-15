import Foundation
import LexiconDomain

/// PUSH_TO_TALK has one cumulative hypothesis and one completed transcript.
/// Authentication belongs in the first frame, never the HTTP request.
struct MuseVoice: StreamingProvider {
    let requiresAcknowledgment = true

    func connectRequest(key: String) -> URLRequest {
        URLRequest(url: URL(string: "wss://api.meta.ai/v1/asr/realtime")!)
    }

    func sessionStart(key: String, terms: [Term]) -> ProviderMessage? {
        struct Handshake: Encodable {
            struct Authorization: Encodable { let accessToken: String }
            let authorization: Authorization
            let model = "muse-voice-transcribe-1.0"
            let audioEncoding = "PCM_16KHZ"
            let mode = "PUSH_TO_TALK"
            let partialMode = "CUMULATIVE"
            // Term selection is owned by the later Lexicon integration.
            let keywords: [String] = []
        }
        let frame = Handshake(authorization: .init(accessToken: "Bearer " + key))
        // This fixed string-only shape cannot fail JSON encoding.
        return .text(String(decoding: try! JSONEncoder().encode(frame), as: UTF8.self))
    }

    func audio(_ chunk: PCMChunk) -> ProviderMessage {
        var data = Data(capacity: chunk.samples.count * 2)
        for sample in chunk.samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return .binary(data)
    }

    func finalize() -> ProviderMessage { .text("{\"type\":\"endStream\"}") }

    func parse(_ message: ProviderMessage) -> ProviderEvent {
        guard case .text(let text) = message,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return .ignore
        }
        guard let type = object["type"] as? String else {
            return object["sessionId"] is String ? .acknowledged : .ignore
        }
        switch type {
        case "transcript":
            guard let transcript = object["transcript"] as? String, let final = object["final"] as? Bool else {
                return .ignore
            }
            return final ? .completed(transcript) : .partial(transcript)
        case "error": return .error("provider error")
        default: return .ignore
        }
    }
}
