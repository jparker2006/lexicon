import Testing
@testable import LocalParakeet

// The window merge copied from FluidAudio (#117): long Dictations are decoded one
// 15 s window at a time and joined here, so these pin what the copy does with the
// two cases every long Dictation hits. Token timestamps are 80 ms encoder frames.

private let vocabulary: [Int: String] = [0: "▁the", 1: "▁cat", 2: "▁sat", 3: "▁on", 4: "▁mat", 5: "▁The"]

private func tokens(_ pairs: [(id: Int, frame: Int)]) -> [SeamMerge.TokenWindow] {
    pairs.map { (token: $0.id, timestamp: $0.frame, confidence: 1, duration: 0) }
}

@Test func aOneWindowClipKeepsTheTokensFluidAudioDecoded() {
    // FluidAudio already sorted and collapsed a window it decoded; collapsing again could
    // drop a word the one-shot path keeps, so a single window passes through untouched.
    let window = tokens([(0, 10), (5, 12), (1, 20)])
    let merged = SeamMerge(vocabulary: vocabulary).merge([window])
    #expect(merged.map(\.token) == [0, 5, 1])
    #expect(merged.map(\.timestamp) == [10, 12, 20])
}

@Test func wordsHeardInBothWindowsOfAnOverlapAreKeptOnce() {
    // The first window ends at frame 187; the next starts at frame 162, so frames 162 to 187
    // are heard twice. "sat on" falls in both.
    let first = tokens([(0, 150), (1, 160), (2, 170), (3, 180)])
    let second = tokens([(2, 170), (3, 180), (0, 185), (4, 190)])
    let merged = SeamMerge(vocabulary: vocabulary).merge([first, second])
    #expect(merged.map(\.token) == [0, 1, 2, 3, 0, 4])  // the cat sat on the mat
    #expect(merged.map(\.timestamp) == merged.map(\.timestamp).sorted())
}
