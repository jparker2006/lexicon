import Testing
@testable import Transcription

// Where each window of a long clip starts (#117), as a pure seam: no model, no
// audio, no clock. The rule is FluidAudio's UnifiedBatchLayout: the first window
// is at 0, then every multiple of the stride that starts inside the clip and
// whose overlap with the clip still reaches past its start. The skeleton returns
// [0] for every clip, so the grid tests fail until the rule is built.

// Parakeet's production grid: 15 s windows with 2 s of overlap at 16 kHz.
private let parakeetGrid = WindowGrid(window: 239_360, overlap: 32_000)

@Test(.timeLimit(.minutes(1))) func parakeetGridHasNoWindowsForAnEmptyClip() {
    #expect(parakeetGrid.stride == 207_360)
    #expect(parakeetGrid.starts(total: 0) == [])
}

@Test(.timeLimit(.minutes(1))) func parakeetGridIsOneWindowForOneSample() {
    #expect(parakeetGrid.starts(total: 1) == [0])
}

// Passes on the skeleton by coincidence (it returns [0] for every clip). It guards
// the other side: a fix that adds a window too early fails here.
@Test(.timeLimit(.minutes(1))) func parakeetGridIsOneWindowUpToTheEndOfTheFirstWindow() {
    // 207_360 + 32_000 == 239_360: a second window would start with no more
    // than the overlap inside the clip, so it is not needed yet.
    #expect(parakeetGrid.starts(total: 239_360) == [0])
}

@Test(.timeLimit(.minutes(1))) func parakeetGridAddsASecondWindowOnceItReachesPastTheOverlap() {
    #expect(parakeetGrid.starts(total: 239_361) == [0, 207_360])
}

@Test(.timeLimit(.minutes(1))) func parakeetGridAddsEachWindowOnlyOnceItsOverlapIsInside() {
    // The third window starts at 414_720, so its overlap ends at 446_720.
    #expect(parakeetGrid.starts(total: 446_720) == [0, 207_360])
    #expect(parakeetGrid.starts(total: 446_721) == [0, 207_360, 414_720])
}

// Hand-computed: 19_200_000 / 207_360 is 92.59, so starts are k * 207_360 for
// k = 0...92 (92 * 207_360 + 32_000 = 19_109_120 < 19_200_000; 93 starts past the end).
@Test(.timeLimit(.minutes(1))) func twentyMinuteClipGetsNinetyThreeWindowsFromZeroToStart92() {
    let starts = parakeetGrid.starts(total: 19_200_000)
    #expect(starts.count == 93)
    #expect(starts.first == 0)
    #expect(starts.last == 19_077_120)
    #expect(starts == referenceStarts(window: 239_360, overlap: 32_000, total: 19_200_000))
}

// Exhaustive on a small grid: every clip length from empty to a few windows.
@Test(.timeLimit(.minutes(1))) func smallGridMatchesTheRuleForEveryClipLength() {
    let mismatch = firstRuleMismatch(WindowGrid(window: 1_000, overlap: 200), totals: Array(0...6_000))
    #expect(mismatch == nil, "\(mismatch ?? "")")
}

// Seeded, so the same clip lengths run on every machine and every run. The
// properties do not use the rule, so a fix that is wrong another way still fails one.
@Test(.timeLimit(.minutes(1))) func gridPropertiesHoldForSeededClipLengths() {
    var generator = SeededGenerator(state: 117)
    let grids = [
        parakeetGrid,
        WindowGrid(window: 1_000, overlap: 200),
        WindowGrid(window: 1_000, overlap: 0),
        WindowGrid(window: 10, overlap: 9),
    ]
    var problems: [String] = []
    for grid in grids {
        var totals = boundaryTotals(grid)
        for _ in 0..<200 {
            totals.append(Int.random(in: 0...(20 * grid.window), using: &generator))
        }
        for total in totals {
            if let problem = propertyViolation(grid, total: total, starts: grid.starts(total: total)) {
                problems.append("window \(grid.window), overlap \(grid.overlap): \(problem)")
            }
        }
        if let mismatch = firstRuleMismatch(grid, totals: totals) {
            problems.append(mismatch)
        }
    }
    #expect(problems.isEmpty, "\(problems.count) clip lengths broke the grid; first: \(problems.first ?? "")")
}

// The rule as FluidAudio writes it, kept apart from the code under test so the
// expectation is not the implementation.
private func referenceStarts(window: Int, overlap: Int, total: Int) -> [Int] {
    guard total > 0 else { return [] }
    let stride = window - overlap
    var starts = [0]
    var start = stride
    while start < total {
        if start + overlap < total { starts.append(start) }
        start += stride
    }
    return starts
}

/// The first clip length where the grid's starts differ from the rule, or nil.
private func firstRuleMismatch(_ grid: WindowGrid, totals: [Int]) -> String? {
    for total in totals {
        let got = grid.starts(total: total)
        let want = referenceStarts(window: grid.window, overlap: grid.overlap, total: total)
        if got != want {
            return "window \(grid.window), overlap \(grid.overlap), total \(total): got \(got), the rule says \(want)"
        }
    }
    return nil
}

/// The properties every grid must have, checked without the rule. Returns the
/// first property that breaks, or nil.
private func propertyViolation(_ grid: WindowGrid, total: Int, starts: [Int]) -> String? {
    let stride = grid.stride
    if starts.isEmpty != (total == 0) {
        return "total \(total) has \(starts.count) windows"
    }
    if let first = starts.first, first != 0 {
        return "total \(total) starts at \(first), not 0"
    }
    for (index, start) in starts.enumerated() {
        if start % stride != 0 {
            return "total \(total): start \(start) is not a multiple of the stride \(stride)"
        }
        if start >= total {
            return "total \(total): start \(start) is outside the clip"
        }
        if index > 0, start <= starts[index - 1] {
            return "total \(total): starts are not increasing at \(start)"
        }
    }
    if let last = starts.last, last + grid.window < total {
        return "total \(total): the last window at \(last) stops short of the end"
    }
    // A window that is complete before the end is decoded while Jake is still
    // talking, so it has to be in the list from the start.
    var start = 0
    while start + grid.window <= total {
        if !starts.contains(start) {
            return "total \(total): the complete window at \(start) is missing"
        }
        start += stride
    }
    return nil
}

/// Clip lengths on each edge of the rule: a window's start, its overlap and its end.
private func boundaryTotals(_ grid: WindowGrid) -> [Int] {
    var totals: [Int] = []
    for k in 0...6 {
        let base = k * grid.stride
        for edge in [0, grid.overlap, grid.window] {
            for delta in [-1, 0, 1] where base + edge + delta >= 0 {
                totals.append(base + edge + delta)
            }
        }
    }
    return totals
}

/// SplitMix64: a fixed seed gives the same sequence on every machine.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
