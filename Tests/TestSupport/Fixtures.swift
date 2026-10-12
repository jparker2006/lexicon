public import Foundation

// Synthesized audio fixtures, shared by every test target. Never a recording.

/// Deterministic 16-bit audio: a few tones plus noise from a fixed-seed LCG,
/// with both extremes (-32768, 32767) and silence in it.
public func syntheticSamples(count: Int) -> [Int16] {
    var seed: UInt32 = 0x1E71_C0DE
    return (0..<count).map { index in
        switch index % 4_000 {
        case 0: return .min
        case 1: return .max
        case 2: return 0
        default:
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let t = Double(index) / 16_000
            let tone = 9_000 * sin(2 * .pi * 220 * t) + 5_000 * sin(2 * .pi * 1_375 * t) + 2_000 * sin(2 * .pi * 6_100 * t)
            return Int16(clamping: Int(tone) + Int(Int16(truncatingIfNeeded: seed >> 16)) / 8)
        }
    }
}

/// 30 s at 16 kHz, for realtime tests that stop, drop or kill a capture partway.
/// A realtime file is read against the wall clock, so the test acts on an
/// explicit signal (a chunk, first audio) and the file's length is the margin:
/// 30 s keeps the end out of reach however loaded the machine.
public func longSamples() -> [Int16] { syntheticSamples(count: 30 * 16_000) }

/// A 16-bit mono PCM WAV, header written by hand so the fixture does not depend
/// on the Apple file APIs it tests.
public func writeWAV(_ samples: [Int16], rate: Int, in dir: URL) throws -> URL {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = samples.count * 2
    data.append(contentsOf: "RIFF".utf8); append(UInt32(36 + bytes))
    data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: "data".utf8); append(UInt32(bytes))
    for sample in samples { append(sample) }
    let url = dir.appending(path: "input-\(rate).wav")
    try data.write(to: url)
    return url
}

public func scratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "lexicon-audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
