// Copied from FluidAudio v0.17.4 (https://github.com/FluidInference/FluidAudio),
// UnifiedAsrManager.swift, UnifiedMelExtractor.swift, UnifiedRnntDecoder.swift and
// UnifiedFeatureProviders.swift, Apache License 2.0. Copyright (c) FluidInference.
// Changed: only the offline int8 encoder is loaded (no tokenizer, vocabulary boosting or
// logging), and the RNNT state lives inside one window's decode, so each window's tokens
// reach the merge raw, as FluidAudio's one-shot path does before it merges them.

@preconcurrency import CoreML
import Accelerate
import FluidAudio
import Foundation
import Transcription

/// Decodes one window of the offline Parakeet Unified encoder at a time, as audio arrives.
///
/// FluidAudio's one-shot path decodes every window and merges them, but keeps the per-window
/// decode internal. This is that decode alone, so `SeamMerge` can join the windows as they
/// are captured and reach the same text.
actor WindowDecoder {
    /// UnifiedAsrManager's offline window: 15 s and a 2 s overlap in whole 80 ms frames.
    static let grid: WindowGrid = {
        let config = UnifiedConfig()
        let window = 15 * config.sampleRate / config.frameSamples * config.frameSamples
        let overlap = min(2 * config.sampleRate, window / 2) / config.frameSamples * config.frameSamples
        return WindowGrid(window: window, overlap: overlap)
    }()
    /// FluidAudio pads every window to 15 s exactly (its layout.windowSamples, 240_000), not to
    /// the grid window.
    static let padded = 15 * UnifiedConfig().sampleRate

    private let config: UnifiedConfig
    private let encoder: MLModel
    private let rnnt: UnifiedRnntDecoder
    private let swiftMel: UnifiedMelExtractor

    private init(config: UnifiedConfig, encoder: MLModel, rnnt: UnifiedRnntDecoder) {
        self.config = config
        self.encoder = encoder
        self.rnnt = rnnt
        self.swiftMel = UnifiedMelExtractor(windowSamples: Self.padded, nMels: config.melFeatures)
    }

    /// Loads the int8 offline encoder, decoder and joint from `folder`, which holds the
    /// parakeet_unified_* bundles. The tokenizer is not loaded: the caller joins the text.
    static func load(from folder: URL) async throws -> WindowDecoder {
        let config = UnifiedConfig()
        // Per-token decoder and joint stay on CPU; only the encoder uses ANE/GPU. Mel is
        // computed in Swift.
        let cpuConfig = MLModelConfiguration()
        cpuConfig.computeUnits = .cpuOnly
        // int8 encoders must not route to the GPU: under `.all` CoreML sends the quantized ops
        // to MPSGraph, which fails its MLIR pass and aborts. Coerce the known-bad int8 default
        // to CPU+ANE.
        let defaults = MLModelConfigurationUtils.defaultConfiguration()
        let encoderConfig: MLModelConfiguration
        if defaults.computeUnits == .all {
            encoderConfig = MLModelConfiguration()
            encoderConfig.computeUnits = .cpuAndNeuralEngine
        } else {
            encoderConfig = defaults
        }
        let encoderFile = folder.appendingPathComponent(
            ModelNames.ParakeetUnified.offlineEncoderFile(precision: .int8))
        let encoder = try await MLModel.load(contentsOf: encoderFile, configuration: encoderConfig)
        let decoder = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(ModelNames.ParakeetUnified.decoderFile),
            configuration: cpuConfig
        )
        let joint = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(ModelNames.ParakeetUnified.jointDecisionFile),
            configuration: cpuConfig
        )
        let rnnt = UnifiedRnntDecoder(decoderModel: decoder, jointDecisionModel: joint, config: config)
        return WindowDecoder(config: config, encoder: encoder, rnnt: rnnt)
    }

    /// One window of the clip that starts at sample `start`: its raw emissions, never sorted or
    /// collapsed, with frames counted from the clip's start (start / 1280 + frame). The RNNT state
    /// starts from zero for each window, as FluidAudio resets it per window.
    func decode(_ samples: [Int16], at start: Int) async throws -> [SeamMerge.TokenWindow] {
        // Int16 to floats in [-1, 1), zero-padded to the encoder's fixed window.
        var window = [Float](repeating: 0, count: Self.padded)
        window.withUnsafeMutableBufferPointer { dst in
            var valid = UnsafeMutableBufferPointer(rebasing: dst[..<samples.count])
            vDSP.convertElements(of: samples, to: &valid)
            vDSP.multiply(1 / 32768, valid, result: &valid)
        }

        // Window to mel (native Swift `AudioMelSpectrogram` + per_feature norm).
        let (mel, melLength) = try swiftMel.features(window: window, validCount: samples.count)

        let encoderOutput = try await encoder.prediction(
            from: UnifiedEncoderFeatureProvider(mel: mel, melLength: melLength))
        guard let encoded = encoderOutput.featureValue(for: "encoder")?.multiArrayValue,
            let encodedLength = encoderOutput.featureValue(for: "encoder_length")?.multiArrayValue
        else {
            throw ASRError.processingFailed("Unified encoder failed to produce output")
        }

        let encoderLength = min(encodedLength[0].intValue, encoded.shape[2].intValue)
        let emissions = try rnnt.decode(
            encoded: encoded, frameRange: 0..<encoderLength, globalFrameOffset: start / config.frameSamples)
        return emissions.map { (token: $0.token, timestamp: $0.frame, confidence: $0.prob, duration: 0) }
    }
}

/// Native-Swift log-mel features for Parakeet Unified, a drop-in replacement for the CoreML
/// `parakeet_unified_preprocessor` bundle.
///
/// Reproduces NeMo's `AudioToMelSpectrogramPreprocessor` exactly as configured in
/// `nvidia/parakeet-unified-en-0.6b` (`model_config.yaml`): `n_fft=512`, `window_size=0.025`
/// (400), `window_stride=0.01` (160), `features=128`, `window=hann` (symmetric), `preemph=0.97`,
/// `log_zero_guard='add'/2^-24`, and crucially **`normalize: per_feature`**, the per-mel-bin
/// mean/variance standardization that the EOU config (`normalize: "NA"`) omits.
/// `AudioMelSpectrogram` supplies the spectrogram; this type adds the per-feature normalization
/// and packs the fixed-shape encoder input.
private struct UnifiedMelExtractor {
    private let mel: AudioMelSpectrogram
    private let nMels: Int
    private let hopLength = 160

    /// Total samples in the (zero-padded) encoder window.
    let windowSamples: Int
    /// Fixed mel frame count the encoder expects for the window (center-padded:
    /// `windowSamples / hop + 1`). Matches the CoreML `mel_shape` last dim.
    let totalFrames: Int

    init(windowSamples: Int, nMels: Int = 128) {
        self.windowSamples = windowSamples
        self.nMels = nMels
        self.totalFrames = windowSamples / hopLength + 1
        self.mel = AudioMelSpectrogram(
            sampleRate: 16000,
            nMels: nMels,
            nFFT: 512,
            hopLength: 160,
            winLength: 400,
            preemph: 0.97,
            padTo: 0,
            windowPeriodic: false
        )
    }

    /// Compute `(mel, melLength)` for one encoder window.
    ///
    /// - Parameters:
    ///   - window: zero-padded buffer of length `windowSamples`; the first `validCount` samples
    ///     are real audio (the rest is padding), matching how the CoreML preprocessor's
    ///     `audio_signal` input is filled.
    ///   - validCount: number of real samples at the head of `window`.
    /// - Returns: `mel` shaped `[1, nMels, totalFrames]` and `melLength` (`[1]`, int32) holding
    ///   the number of valid mel frames, identical contract to the CoreML preprocessor outputs.
    func features(window: [Float], validCount: Int) throws -> (mel: MLMultiArray, length: MLMultiArray) {
        // Time-major [totalFrames * nMels] raw log-mel over the full window.
        var flat = mel.computeFlatTransposed(
            audio: window,
            lastAudioSample: 0,
            paddingMode: .center,
            expectedFrameCount: totalFrames
        ).mel

        // NeMo `get_seq_len` (center padding, stft_pad_amount=0):
        // floor((L + n_fft - n_fft) / hop) = floor(L / hop). Note: NO `+1`. The mel *tensor* has
        // `floor(L/hop)+1` frames, but the valid length reported to the encoder (and used for
        // per_feature stats + masking) is one less, so the final tensor frame is always normalized
        // to 0. Getting this off by one only nudges WER at large chunks but balloons it at tiny
        // chunks, whose decoded frames sit right at this boundary.
        let validFrames = min(validCount / hopLength, totalFrames)
        normalizePerFeature(&flat, frames: totalFrames, validFrames: validFrames)

        let melArray = try MLMultiArray(
            shape: [1, NSNumber(value: nMels), NSNumber(value: totalFrames)], dataType: .float32)
        melArray.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
            // Contiguous [1, nMels, T]: element [0, m, t] is at offset m*T + t.
            for t in 0..<totalFrames {
                let base = t * nMels
                for m in 0..<nMels {
                    ptr[m * totalFrames + t] = flat[base + m]
                }
            }
        }

        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: validFrames)
        return (melArray, lengthArray)
    }

    /// NeMo `normalize_batch(..., normalize_type="per_feature")`: for each mel bin, subtract the
    /// mean and divide by the unbiased std (`+1e-5`) computed over the valid frames, applied to
    /// all valid frames; pad frames are zeroed.
    private func normalizePerFeature(_ x: inout [Float], frames: Int, validFrames: Int) {
        guard validFrames > 0 else {
            for i in x.indices { x[i] = 0 }
            return
        }
        let denom = Float(validFrames > 1 ? validFrames - 1 : 1)
        for m in 0..<nMels {
            var mean: Float = 0
            for t in 0..<validFrames { mean += x[t * nMels + m] }
            mean /= Float(validFrames)

            var varSum: Float = 0
            for t in 0..<validFrames {
                let d = x[t * nMels + m] - mean
                varSum += d * d
            }
            let std = (varSum / denom).squareRoot() + 1e-5

            for t in 0..<frames {
                x[t * nMels + m] = t < validFrames ? (x[t * nMels + m] - mean) / std : 0
            }
        }
    }
}

/// Greedy RNNT decode loop for Parakeet Unified 0.6B.
///
/// Wraps the CoreML decoder (RNNT prediction network) and single-step joint-decision models;
/// argmax, probability, and blank handling come from the joint-decision model itself. Each
/// window decodes from a zero state, so the state is local to one `decode` call.
private struct UnifiedRnntDecoder {
    struct Emission {
        /// Emitted (non-blank) token id.
        let token: Int
        /// Encoder frame the token was emitted at, offset by the caller's global frame base.
        let frame: Int
        /// Softmax probability of the emitted token.
        let prob: Float
    }

    private let decoderModel: MLModel
    private let jointDecisionModel: MLModel
    private let config: UnifiedConfig

    init(decoderModel: MLModel, jointDecisionModel: MLModel, config: UnifiedConfig) {
        self.decoderModel = decoderModel
        self.jointDecisionModel = jointDecisionModel
        self.config = config
    }

    private static func zeroState(config: UnifiedConfig) throws -> MLMultiArray {
        let state = try MLMultiArray(
            shape: [NSNumber(value: config.decoderLayers), 1, NSNumber(value: config.decoderHidden)],
            dataType: .float32
        )
        // A fresh MLMultiArray is not guaranteed zeroed, and FluidAudio's `reset(to:)` is internal.
        state.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
            ptr.update(repeating: 0)
        }
        return state
    }

    /// Greedy RNNT over encoder frames `frameRange` of `encoded` [1, D, T], from a zero state.
    /// Emitted frames are reported as `globalFrameOffset + t`.
    func decode(
        encoded: MLMultiArray,
        frameRange: Range<Int>,
        globalFrameOffset: Int
    ) throws -> [Emission] {
        // (h, c) are the LSTM state BEFORE `currentToken` is consumed; the first decoder call
        // re-derives the cached decoder output by applying the blank token to the zero state.
        var currentToken = Int32(config.blankIdx)
        var currentH = try Self.zeroState(config: config)
        var currentC = try Self.zeroState(config: config)
        var emissions: [Emission] = []

        var decoderStep = try runDecoder(token: currentToken, h: currentH, c: currentC)

        for t in frameRange {
            let encStep = try extractEncoderStep(from: encoded, timeIndex: t)

            for _ in 0..<config.maxSymbolsPerFrame {
                let jointOutput = try jointDecisionModel.prediction(
                    from: UnifiedJointDecisionFeatureProvider(
                        encoderStep: encStep,
                        decoderStep: decoderStep.output
                    )
                )
                guard let tokenArray = jointOutput.featureValue(for: "token_id")?.multiArrayValue else {
                    throw ASRError.processingFailed("Unified joint decision missing token_id")
                }
                let tokenId = tokenArray[0].int32Value

                if tokenId == Int32(config.blankIdx) {
                    break
                }
                let prob = jointOutput.featureValue(for: "token_prob")?.multiArrayValue?[0].floatValue ?? 0
                emissions.append(
                    Emission(token: Int(tokenId), frame: globalFrameOffset + t, prob: prob)
                )
                currentToken = tokenId
                currentH = decoderStep.h
                currentC = decoderStep.c
                decoderStep = try runDecoder(token: currentToken, h: currentH, c: currentC)
            }
        }

        return emissions
    }

    private struct DecoderStep {
        let output: MLMultiArray
        let h: MLMultiArray
        let c: MLMultiArray
    }

    private func runDecoder(token: Int32, h: MLMultiArray, c: MLMultiArray) throws -> DecoderStep {
        let targets = try MLMultiArray(shape: [1, 1], dataType: .int32)
        targets[0] = NSNumber(value: token)
        let targetLength = try MLMultiArray(shape: [1], dataType: .int32)
        targetLength[0] = 1

        let output = try decoderModel.prediction(
            from: UnifiedDecoderFeatureProvider(
                targets: targets,
                targetLength: targetLength,
                hIn: h,
                cIn: c
            )
        )
        guard let decoderOut = output.featureValue(for: "decoder")?.multiArrayValue,
            let hOut = output.featureValue(for: "h_out")?.multiArrayValue,
            let cOut = output.featureValue(for: "c_out")?.multiArrayValue
        else {
            throw ASRError.processingFailed("Unified decoder failed")
        }
        // Decoder output is [1, 640, 1] (U=1 export); h/c become the state for the NEXT decoder
        // call only after this token is accepted.
        return DecoderStep(output: decoderOut, h: hOut, c: cOut)
    }

    private func extractEncoderStep(from encoded: MLMultiArray, timeIndex: Int) throws -> MLMultiArray {
        let dim = encoded.shape[1].intValue
        let step = try MLMultiArray(shape: [1, NSNumber(value: dim), 1], dataType: .float32)

        let srcPtr = encoded.dataPointer.bindMemory(to: Float.self, capacity: encoded.count)
        let dstPtr = step.dataPointer.bindMemory(to: Float.self, capacity: step.count)
        let stride1 = encoded.strides[1].intValue
        let stride2 = encoded.strides[2].intValue

        for c in 0..<dim {
            dstPtr[c] = srcPtr[c * stride1 + timeIndex * stride2]
        }
        return step
    }
}

/// Hyperoptimized Mel Feature Provider
private final class UnifiedEncoderFeatureProvider: MLFeatureProvider {
    let featureNames: Set<String> = ["mel", "mel_length"]

    let mel: MLFeatureValue
    let melLength: MLFeatureValue

    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName.count == 3 { return mel }
        return melLength
    }

    init(mel: MLMultiArray, melLength: MLMultiArray) {
        self.mel = MLFeatureValue(multiArray: mel)
        self.melLength = MLFeatureValue(multiArray: melLength)
    }
}

/// Hyperoptimized Decoder Model Feature Provider
private final class UnifiedDecoderFeatureProvider: MLFeatureProvider {
    let featureNames: Set<String> = ["targets", "target_length", "h_in", "c_in"]

    let hIn: MLFeatureValue
    let cIn: MLFeatureValue
    let targets: MLFeatureValue
    let targetLength: MLFeatureValue

    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName.count {
        case 4: return featureName.first == "h" ? hIn : cIn
        case 7: return targets
        default: return targetLength
        }
    }

    init(
        targets: MLMultiArray,
        targetLength: MLMultiArray,
        hIn: MLMultiArray,
        cIn: MLMultiArray
    ) {
        self.targets = MLFeatureValue(multiArray: targets)
        self.targetLength = MLFeatureValue(multiArray: targetLength)
        self.hIn = MLFeatureValue(multiArray: hIn)
        self.cIn = MLFeatureValue(multiArray: cIn)
    }
}

/// Hyperoptimized Joint Decision Model Feature Provider
private final class UnifiedJointDecisionFeatureProvider: MLFeatureProvider {
    let featureNames: Set<String> = ["encoder_step", "decoder_step"]

    let encoderStep: MLFeatureValue
    let decoderStep: MLFeatureValue

    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName.first == "e" { return encoderStep }
        return decoderStep
    }

    init(encoderStep: MLMultiArray, decoderStep: MLMultiArray) {
        self.encoderStep = MLFeatureValue(multiArray: encoderStep)
        self.decoderStep = MLFeatureValue(multiArray: decoderStep)
    }
}
