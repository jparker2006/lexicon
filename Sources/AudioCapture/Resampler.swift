import AVFAudio
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
    private var supplied = false

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
        convertCall = convert
        self.input = input
        self.output = output
    }

    /// Converts the `input` buffer's frames. `emit` gets whatever 16 kHz samples
    /// came out (the converter may hold a few back until the next block).
    func convert(emit: (UnsafeBufferPointer<Int16>) -> Void) {
        supplied = false
        run(endOfStream: false, emit: emit)
    }

    /// End of the stream: emits the samples the converter still holds.
    func flush(emit: (UnsafeBufferPointer<Int16>) -> Void) {
        supplied = true
        run(endOfStream: true, emit: emit)
    }

    private func run(endOfStream: Bool, emit: (UnsafeBufferPointer<Int16>) -> Void) {
        while true {
            output.frameLength = 0
            let (status, _) = convertCall(converter, output) { _, inputStatus in
                if self.supplied {
                    inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                    return nil
                }
                self.supplied = true
                inputStatus.pointee = .haveData
                return self.input
            }
            let produced = Int(output.frameLength)
            if produced > 0 { emit(UnsafeBufferPointer(start: output.int16ChannelData![0], count: produced)) }
            // .haveData means the output filled up and more may be waiting.
            guard status == .haveData, produced > 0 else { return }
        }
    }
}
