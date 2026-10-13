import AVFAudio
import os
import LexiconDomain

/// Mono Float32 at the input rate to 16 kHz mono Int16, streamed block by block.
/// `AVAudioConverter` with MinimumPhase at max quality (#4): flat to 7 kHz,
/// aliases at -163 dB, 43 ms of CPU per minute of audio. The default setting
/// lets aliases through at -31 dB. Dither stays off (the default), so a 16 kHz
/// input whose floats are exact Int16 values passes through bit-exact.
///
/// Confined to the writer queue. `@unchecked Sendable` only because the
/// converter's input block is `@Sendable`: the converter calls it synchronously,
/// inside `convert`, on that same queue.
final class Resampler: @unchecked Sendable {
    /// One `AVAudioConverter.convert(to:error:withInputFrom:)`, returning its status and error.
    typealias Convert = @Sendable (AVAudioConverter, AVAudioPCMBuffer, @escaping AVAudioConverterInputBlock)
        -> (AVAudioConverterOutputStatus, NSError?)

    static let realConvert: Convert = { converter, output, input in
        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: input)
        return (status, error)
    }

    let input: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private let convertCall: Convert
    private let output: AVAudioPCMBuffer
    private let ratio: Double
    private var supplied = false
    /// Input frames converted, and 16 kHz frames emitted: what the converter
    /// still holds is the difference.
    private var consumed = 0
    private var emitted = 0

    /// `maxFrames` is the largest block `convert` will be handed.
    init?(inputRate: Double, maxFrames: AVAudioFrameCount, convert: @escaping Convert = realConvert) {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCM16k.sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: maxFrames)
        else { return nil }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_MinimumPhase
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let ratio = Double(PCM16k.sampleRate) / inputRate
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount((Double(maxFrames) * ratio).rounded(.up)) + 512)
        else { return nil }
        self.converter = converter
        self.ratio = ratio
        convertCall = convert
        self.input = input
        self.output = output
    }

    /// Converts the `input` buffer's frames. `emit` gets whatever 16 kHz samples
    /// came out (the converter may hold a few back until the next block).
    /// Returns the audio lost: the whole block when the converter fails on it,
    /// since its output is undefined and the next drain overwrites `input`. What
    /// the converter held from earlier blocks still comes out after.
    @discardableResult
    func convert(emit: (UnsafeBufferPointer<Int16>) -> Void) -> Duration {
        supplied = false
        let frames = Int(input.frameLength)
        guard run(endOfStream: false, emit: emit) else { return Duration(frames: frames, rate: input.format.sampleRate) }
        consumed += frames
        return .zero
    }

    /// End of the stream: emits the samples the converter still holds. Returns
    /// those samples as lost when the converter fails on them.
    @discardableResult
    func flush(emit: (UnsafeBufferPointer<Int16>) -> Void) -> Duration {
        supplied = true
        guard run(endOfStream: true, emit: emit) else {
            return Duration(frames: max(0, Int((Double(consumed) * ratio).rounded()) - emitted), rate: Double(PCM16k.sampleRate))
        }
        return .zero
    }

    /// False when the converter answered `.error`; its output is not emitted.
    private func run(endOfStream: Bool, emit: (UnsafeBufferPointer<Int16>) -> Void) -> Bool {
        while true {
            output.frameLength = 0
            let (status, error) = convertCall(converter, output) { _, inputStatus in
                if self.supplied {
                    inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                    return nil
                }
                self.supplied = true
                inputStatus.pointee = .haveData
                return self.input
            }
            if status == .error {
                // The code only: the error's text stays out of the log (review.md, private data).
                Self.log.error("converter failed\(endOfStream ? " at the end" : "", privacy: .public): \(error?.code ?? 0, privacy: .public)")
                return false
            }
            let produced = Int(output.frameLength)
            if produced > 0 {
                emitted += produced
                emit(UnsafeBufferPointer(start: output.int16ChannelData![0], count: produced))
            }
            // .haveData means the output filled up and more may be waiting.
            guard status == .haveData, produced > 0 else { return true }
        }
    }

    private static let log = Logger(subsystem: "Lexicon", category: "audio")
}
