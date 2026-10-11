import Foundation
import LexiconDomain

/// Meta Muse Voice Transcribe realtime (#8): wss://api.meta.ai/v1/asr/realtime,
/// keywords at session start, `endStream` on fn up. Meta ends the session on
/// finalize, so every Dictation opens a new socket (done at fn-down).
struct MuseVoice: StreamingProvider {
    func connectRequest(key: String) -> URLRequest { fatalError("not implemented") }
    func sessionStart(terms: [Term]) -> ProviderMessage? { fatalError("not implemented") }
    func audio(_ chunk: PCMChunk) -> ProviderMessage { fatalError("not implemented") }
    func finalize() -> ProviderMessage { fatalError("not implemented") }
    func parse(_ message: ProviderMessage) -> ProviderEvent { fatalError("not implemented") }
}
