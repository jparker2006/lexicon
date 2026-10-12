import Testing
@testable import LocalParakeet

// The window merge copied from FluidAudio (#117): long Dictations are decoded one
// 15 s window at a time and joined here, so these pin what FluidAudio's one-shot path
// does with the raw windows. Token timestamps are 80 ms encoder frames.

private let vocabulary: [Int: String] = [
    0: "▁the", 1: "▁cat", 2: "▁sat", 3: "▁on", 4: "▁mat", 5: "▁Meeting", 6: "▁meeting",
]

private func tokens(_ pairs: [(id: Int, frame: Int)]) -> [SeamMerge.TokenWindow] {
    pairs.map { (token: $0.id, timestamp: $0.frame, confidence: 1, duration: 0) }
}

@Test func aOneWindowClipCollapsesItsRepeatsOnceAsTheOneShotPathDoes() {
    // FluidAudio collapses a case-only repeat once, after the merge, even for one window:
    // "Meeting Meeting meeting Meeting" becomes "Meeting meeting". Collapsing twice gives "meeting".
    let window = tokens([(5, 10), (5, 12), (6, 14), (5, 16)])
    #expect(SeamMerge(vocabulary: vocabulary).text([window]) == "Meeting meeting")
}

@Test func wordsHeardInBothWindowsOfAnOverlapAreKeptOnce() {
    // The first window ends at frame 187; the next starts at frame 162, so frames 162 to 187
    // are heard twice. "sat on" falls in both.
    let first = tokens([(0, 150), (1, 160), (2, 170), (3, 180)])
    let second = tokens([(2, 170), (3, 180), (0, 185), (4, 190)])
    #expect(SeamMerge(vocabulary: vocabulary).text([first, second]) == "the cat sat on the mat")
}
