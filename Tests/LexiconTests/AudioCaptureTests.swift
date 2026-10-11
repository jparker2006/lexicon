import Foundation
import Testing
@testable import AudioCapture
import LexiconDomain

// The never-lose writer (#43), driven by file input: no mic. Fixtures are
// synthesized here, never recorded.

@Test func aSixteenKilohertzWavReadsBackBitExact() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 40_000)  // 2.5 s
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/one.caf")  // audio/ does not exist yet

    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: caf)
    let stream = capture.feed
    let feed = Task { await collect(stream) }
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    #expect(take.clip.samples == source)
    let chunks = await feed.value
    #expect(chunks.flatMap(\.samples) == source)
    #expect(chunks.map(\.index) == Array(chunks.indices))
    #expect(chunks.allSatisfy { $0.samples.count <= 1_600 })  // packets of at most 100 ms
    #expect(take.summary.storage == .onDisk)
    #expect(take.summary.duration == .milliseconds(2_500))
    #expect(CAFFile.state(of: caf) == .closed)
    #expect(try CAFFile.read(caf).samples == source)
}

@Test func killingTheWriterMidRecordingLeavesAFileThatReadsBackBitExact() async throws {
    // The child records at the speed of speech and is SIGKILLed from another
    // thread at an arbitrary moment while its reader and writer queue are still
    // running: no stop, no close. (Not timed to land inside a write() call.)
    let result = try #require(await #expect(processExitsWith: .signal(SIGKILL), observing: [\.standardOutputContent]) {
        let dir = try scratchDirectory()
        let wav = try writeWAV(longSamples(), rate: 16_000, in: dir)
        let caf = dir.appending(path: "audio/killed.caf")
        report("caf \(caf.path)")
        let recorder = Recorder()
        let capture = try await recorder.start(.file(wav, pace: .realtime), writingTo: caf)
        var written = 0
        for await chunk in capture.feed {
            written += chunk.samples.count
            report("written \(written)")  // a chunk is yielded only after write()
            if written >= 20_000 {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(37)) { kill(getpid(), SIGKILL) }
            }
        }
        Issue.record("the feed finished before the kill")
    })

    let lines = String(decoding: result.standardOutputContent, as: UTF8.self).split(separator: "\n")
    let caf = URL(filePath: String(try #require(lines.first { $0.hasPrefix("caf ") }).dropFirst(4)))
    let lastWritten = try #require(lines.last { $0.hasPrefix("written ") }.flatMap { Int($0.dropFirst(8)) })
    let source = longSamples()

    #expect(CAFFile.state(of: caf) == .open)  // data size left at -1
    let survived = try CAFFile.read(caf).samples
    #expect(survived.count >= lastWritten)
    #expect(survived.count < source.count)
    #expect(survived == Array(source.prefix(survived.count)))

    // Recovery's half (#59 calls it): finalizing writes the real size and changes
    // no sample, and a power cut's torn last packet (here, one stray byte) is cut off.
    let torn = caf.deletingLastPathComponent().appending(path: "torn.caf")
    try FileManager.default.copyItem(at: caf, to: torn)
    let handle = try FileHandle(forWritingTo: torn)
    try handle.seekToEnd()
    try handle.write(contentsOf: [0x7F])
    try handle.close()
    for file in [caf, torn] {
        try CAFFile.finalize(file)
        #expect(CAFFile.state(of: file) == .closed)
        #expect(try CAFFile.read(file).samples == survived)
        try CAFFile.finalize(file)  // idempotent
    }
}

@Test func fortyEightKilohertzIsResampledToSixteen() async throws {
    let dir = try scratchDirectory()
    let source = (0..<48_000).map { Int16((sin(2 * Double.pi * 1_000 * Double($0) / 48_000) * 16_384).rounded()) }
    let wav = try writeWAV(source, rate: 48_000, in: dir)
    let caf = dir.appending(path: "resampled.caf")

    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: caf)
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    let out = take.clip.samples
    #expect(abs(out.count - 16_000) <= 16)  // 1 s, give or take a millisecond
    let middle = out[4_000..<12_000].map { Double($0) }
    let rms = (middle.reduce(0) { $0 + $1 * $1 } / Double(middle.count)).squareRoot()
    #expect(abs(20 * log10(rms / (16_384 / 2.0.squareRoot()))) < 0.5)  // a 1 kHz tone keeps its level
    let crossings = zip(middle, middle.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    #expect(abs(crossings - 1_000) <= 4)  // and its pitch: 2 crossings per cycle, 0.5 s
    #expect(try CAFFile.read(caf).samples == out)
}

@Test func stoppingBeforeTheEndKeepsEverythingRead() async throws {
    let dir = try scratchDirectory()
    let source = longSamples()
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let caf = dir.appending(path: "early.caf")

    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .realtime), writingTo: caf)
    let signals = capture.signals
    var feed = capture.feed.makeAsyncIterator()
    var heard: [Int16] = []
    for _ in 0..<3 {
        let chunk = await feed.next()
        heard += try #require(chunk).samples
    }
    let take = await capture.stop(.immediately)
    while let chunk = await feed.next() { heard += chunk.samples }
    await recorder.settle()

    #expect(take.clip.samples == heard)  // every chunk the feed gave, before and after the stop
    #expect(take.clip.samples.count < source.count)
    #expect(take.clip.samples == Array(source.prefix(take.clip.samples.count)))
    #expect(await signals.inputEnded() == nil)  // stopped, not ended
    #expect(take.summary.startGap != nil)
    #expect(try CAFFile.read(caf).samples == take.clip.samples)
}

@Test func aDroppedCaptureStillClosesItsFile() async throws {
    let dir = try scratchDirectory()
    let source = longSamples()
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let caf = dir.appending(path: "dropped.caf")

    let recorder = Recorder()
    var heard = 0
    do {
        let capture = try await recorder.start(.file(wav, pace: .realtime), writingTo: caf)
        var feed = capture.feed.makeAsyncIterator()
        for _ in 0..<3 {
            let chunk = await feed.next()
            heard += try #require(chunk).samples.count
        }
    }  // dropped here, mid-file, without stop
    await recorder.settle()

    #expect(CAFFile.state(of: caf) == .closed)
    let kept = try CAFFile.read(caf).samples
    #expect(kept.count >= heard && kept.count < source.count)
    #expect(kept == Array(source.prefix(kept.count)))
}

@Test func whenTheFileCannotBeWrittenTheAudioStaysInRAM() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 16_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let blocker = dir.appending(path: "audio")
    try Data().write(to: blocker)  // a plain file where the audio folder should be

    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: blocker.appending(path: "x.caf"))
    let problems = capture.signals.problems
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))

    #expect(take.clip.samples == source)
    #expect(take.summary.storage == .ramOnly)
    #expect(await problems.first { _ in true } == .diskTrouble)
}

@Test func anUnreadableFileFailsToStart() async throws {
    let dir = try scratchDirectory()
    let junk = dir.appending(path: "junk.wav")
    try Data("not audio".utf8).write(to: junk)
    await #expect(throws: RecorderError.self) {
        _ = try await Recorder().start(.file(junk, pace: .asFastAsPossible), writingTo: dir.appending(path: "x.caf"))
    }
    #expect(CAFFile.state(of: junk) == .unreadable)
}

@Test func theRingWrapsAndRefusesWhatDoesNotFit() {
    let ring = SPSCRing(capacityFrames: 8)
    var out = [Float](repeating: 0, count: 8)
    let input: [Float] = (0..<12).map(Float.init)

    #expect(input.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0[0..<6])) } == 6)
    #expect(out.withUnsafeMutableBufferPointer { ring.read(into: UnsafeMutableBufferPointer(rebasing: $0[0..<4])) } == 4)
    #expect(Array(out[0..<4]) == [0, 1, 2, 3])
    // 2 frames left in the ring, room for 6: of the 8 offered, 6 fit, wrapping around the end.
    #expect(input.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0[4..<12])) } == 6)
    #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 8)
    #expect(out == [4, 5, 4, 5, 6, 7, 8, 9])
    #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 0)
}

@Test(.timeLimit(.minutes(1))) func stoppingACaptureTwiceIsACompileError() async throws {
    let once = try await compile("""
        func run(_ capture: consuming LiveCapture) async { _ = await capture.stop(.immediately) }
        """)
    #expect(once.status == 0, "control snippet must compile: \(once.output)")

    let twice = try await compile("""
        func run(_ capture: consuming LiveCapture) async {
            _ = await capture.stop(.immediately)
            _ = await capture.stop(.immediately)
        }
        """)
    #expect(twice.status != 0)
    #expect(twice.output.contains("consumed more than once"), "\(twice.output)")
}

// MARK: Fixtures

/// Deterministic 16-bit audio: a few tones plus noise from a fixed-seed LCG,
/// with both extremes (-32768, 32767) and silence in it.
func syntheticSamples(count: Int) -> [Int16] {
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
func longSamples() -> [Int16] { syntheticSamples(count: 30 * 16_000) }

/// A 16-bit mono PCM WAV, header written by hand so the fixture does not depend
/// on the Apple file APIs it tests.
func writeWAV(_ samples: [Int16], rate: Int, in dir: URL) throws -> URL {
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

func scratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "lexicon-audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func collect(_ feed: AudioFeed) async -> [PCMChunk] {
    var chunks: [PCMChunk] = []
    for await chunk in feed { chunks.append(chunk) }
    return chunks
}

/// Unbuffered, so nothing is lost to SIGKILL.
func report(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Compiles `source` against the AudioCapture module this test run built, as
/// far as SIL: ownership ("consumed more than once") is checked there, after type checking.
/// `runChild` blocks no thread while swiftc runs: blocking a cooperative-pool
/// thread for its 6 to 10 s starves the realtime audio tests on a 3-core runner.
func compile(_ source: String) async throws -> (status: Int32, output: String) {
    var image = Dl_info()
    try #require(dladdr(#dsohandle, &image) != 0)
    var bundle = URL(filePath: String(cString: image.dli_fname))
    while bundle.pathExtension != "xctest" {
        try #require(bundle.pathComponents.count > 1, "test binary is not inside an .xctest bundle")
        bundle.deleteLastPathComponent()
    }
    let modules = bundle.deletingLastPathComponent().appending(path: "Modules")
    let file = try scratchDirectory().appending(path: "snippet.swift")
    try ("import AudioCapture\n" + source).write(to: file, atomically: true, encoding: .utf8)
    #if arch(arm64)
    let target = "arm64-apple-macos26.0"
    #else
    let target = "x86_64-apple-macos26.0"
    #endif
    return try await runChild(URL(filePath: "/usr/bin/xcrun"), [
        "swiftc", "-emit-sil", "-o", "/dev/null", "-swift-version", "6", "-target", target, "-I", modules.path, file.path,
    ])
}
