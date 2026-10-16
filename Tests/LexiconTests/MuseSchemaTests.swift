import Foundation
import Testing
import LexiconDomain
@testable import Transcription

@Suite struct MuseSchemaTests {
    private let provider = MuseVoice()

    @Test func connectUsesRealtimeWebSocketWithoutHTTPAuthorization() {
        let request = provider.connectRequest(key: "synthetic-key")

        #expect(request.url?.absoluteString == "wss://api.meta.ai/v1/asr/realtime")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func sessionStartUsesPublicModelAndExactPushToTalkFields() throws {
        let message = try #require(provider.sessionStart(key: "synthetic-key", terms: [Term(text: "gstack"), Term(text: "Xcode")]))
        guard case .text(let payload) = message else {
            Issue.record("Muse session start must be a text frame")
            return
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])

        #expect(Set(object.keys) == Set(["authorization", "model", "audioEncoding", "mode", "partialMode", "keywords"]))
        #expect(object["authorization"] as? [String: String] == ["accessToken": "Bearer synthetic-key"])
        #expect(object["model"] as? String == "muse-voice-transcribe-1.0")
        #expect(CloudModel.museVoice.rawValue == "meta.muse-voice-transcribe-1.0")
        #expect(object["audioEncoding"] as? String == "PCM_16KHZ")
        #expect(object["mode"] as? String == "PUSH_TO_TALK")
        #expect(object["partialMode"] as? String == "CUMULATIVE")
        #expect(object["keywords"] as? [String] == [])
    }

    @Test func audioEncodesSignedSamplesAsLittleEndianPCM() throws {
        let chunk = PCMChunk(index: 0, samples: [Int16.min, -2, -1, 0, 1, 2, Int16.max])

        guard case .binary(let data) = provider.audio(chunk) else {
            Issue.record("Muse audio must be a binary frame")
            return
        }

        #expect(Array(data) == [
            0x00, 0x80, // Int16.min
            0xfe, 0xff, // -2
            0xff, 0xff, // -1
            0x00, 0x00, // 0
            0x01, 0x00, // 1
            0x02, 0x00, // 2
            0xff, 0x7f, // Int16.max
        ])
    }

    @Test func finalizeSendsEndStream() throws {
        guard case .text(let payload) = provider.finalize() else {
            Issue.record("Muse finalize must be a text frame")
            return
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])

        #expect(object.count == 1)
        #expect(object["type"] as? String == "endStream")
    }

    @Test func acknowledgmentIsRecognizedAndHasNoEventType() throws {
        let payload = try jsonText(["sessionId": "session-123"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])

        #expect(Set(object.keys) == Set(["sessionId"]))
        #expect(provider.parse(.text(payload)) == .acknowledged)
    }

    @Test func transcriptFinalFlagControlsPartialAndFinalEvents() throws {
        let partial = try jsonText(["type": "transcript", "transcript": "ship the", "final": false])
        let final = try jsonText(["type": "transcript", "transcript": "Ship the release.", "final": true])

        #expect(provider.parse(.text(partial)) == .partial("ship the"))
        #expect(provider.parse(.text(final)) == .completed("Ship the release."))
    }

    @Test func speechEndDoesNotEndTheSession() throws {
        let payload = try jsonText(["type": "speechEnd"])

        #expect(provider.parse(.text(payload)) != .sessionEnded)
    }

    @Test func unknownProviderEventIsIgnored() throws {
        let payload = try jsonText(["type": "futureEvent", "value": 7])

        #expect(provider.parse(.text(payload)) == .ignore)
    }

    @Test func providerErrorsDoNotEchoBodiesOrCredentials() throws {
        let credential = "synthetic-key"
        let body = "provider rejected request with token \(credential)"
        let payload = try jsonText(["type": "error", "message": body])
        let event = provider.parse(.text(payload))

        #expect(event == .error("provider error"))
        #expect(!String(describing: event).contains(credential))
        #expect(!String(describing: event).contains(body))
    }
}

private func jsonText(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
