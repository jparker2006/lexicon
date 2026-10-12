// Copied from FluidAudio v0.17.4 (https://github.com/FluidInference/FluidAudio),
// ChunkProcessor.swift and SequenceMatcher.swift, Apache License 2.0.
// Copyright (c) FluidInference. Changed: only the overlap merge the offline
// Parakeet Unified path uses, gathered into one type.

import FluidAudio
import Foundation

/// FluidAudio's one-shot Parakeet Unified path merges its 15 s windows with the overlap
/// merge below. Lexicon decodes the same windows one at a time, as audio arrives, so it
/// merges them here to get the same text as that path.
struct SeamMerge: Sendable {
    typealias TokenWindow = (token: Int, timestamp: Int, confidence: Float, duration: Int)

    let vocabulary: [Int: String]
    private let spliceSafeTokenIds: Set<Int>?
    private let caseVariantIds: [Int: Int]?
    // 2.0 s overlap (frame-aligned) to give the decoder slack when merging windows.
    private let overlapSeconds: Double = 2.0

    init(vocabulary: [Int: String]) {
        self.vocabulary = vocabulary
        spliceSafeTokenIds = Self.spliceSafeTokenIds(vocabulary: vocabulary)
        caseVariantIds = Self.caseVariantCanonicalIds(vocabulary: vocabulary)
    }

    /// The windows' tokens, in window order, merged as UnifiedAsrManager.decodedTokens does:
    /// fold mergeChunks over the windows, sort by timestamp, then collapse seam duplicates.
    /// Each window comes from `transcribeWithTimings`, which already sorted and collapsed
    /// it, so a one-window clip is returned as it is: the one-shot path's tokens exactly.
    func merge(_ windows: [[TokenWindow]]) -> [TokenWindow] {
        if windows.count == 1 { return windows[0] }
        var merged: [TokenWindow] = []
        for windowTokens in windows {
            merged = merged.isEmpty ? windowTokens : mergeChunks(merged, windowTokens)
        }
        merged.sort { $0.timestamp < $1.timestamp }
        return collapseSeamWordDuplicates(merged)
    }

    /// Token IDs that may safely start a seam splice: word-initial (`▁`) or
    /// punctuation-only pieces. Nil for an empty vocabulary.
    private static func spliceSafeTokenIds(vocabulary: [Int: String]) -> Set<Int>? {
        guard !vocabulary.isEmpty else { return nil }
        var ids = Set<Int>()
        for (id, piece) in vocabulary where isSpliceSafePiece(piece) {
            ids.insert(id)
        }
        return ids
    }

    /// Maps token IDs with a case-only twin to a shared canonical ID so the
    /// overlap matcher aligns `▁Meeting`/`▁meeting` at seams. Nil for an empty vocabulary.
    private static func caseVariantCanonicalIds(vocabulary: [Int: String]) -> [Int: Int]? {
        guard !vocabulary.isEmpty else { return nil }
        var groups: [String: [Int]] = [:]
        for (id, piece) in vocabulary {
            groups[piece.lowercased(), default: []].append(id)
        }
        var canon: [Int: Int] = [:]
        for (folded, ids) in groups where ids.count > 1 {
            // Lower-case variant is canonical so the collapse knows which
            // copy of a seam duplicate to keep.
            let canonical = ids.first { vocabulary[$0] == folded } ?? ids.min()!
            for id in ids { canon[id] = canonical }
        }
        return canon.isEmpty ? nil : canon
    }

    /// Drops an adjacent case-only duplicate of a seam word ("have Have a") left by a
    /// false sentence start, at word granularity. The collapse conditions are deliberately
    /// narrow: anything else is left alone.
    private func collapseSeamWordDuplicates(_ tokens: [TokenWindow]) -> [TokenWindow] {
        guard !vocabulary.isEmpty, tokens.count > 1 else { return tokens }
        let overlapFrames = Int((overlapSeconds / ASRConstants.secondsPerEncoderFrame).rounded())

        func piece(_ id: Int) -> String { vocabulary[id] ?? "" }

        struct Word {
            var tokens: [TokenWindow]
            var core: String
            var startTimestamp: Int
            var endsSentence: Bool
        }

        // Segment the token stream into words on word-initial pieces.
        var words: [Word] = []
        for token in tokens {
            if words.isEmpty || isWordBoundary(piece(token.token)) {
                words.append(Word(tokens: [token], core: "", startTimestamp: token.timestamp, endsSentence: false))
            } else {
                words[words.count - 1].tokens.append(token)
            }
        }

        let strippable = CharacterSet.punctuationCharacters.union(.whitespaces)
        for index in words.indices {
            var text = ""
            for token in words[index].tokens {
                text += stripWordBoundaryPrefix(piece(token.token))
            }
            words[index].core = text.trimmingCharacters(in: strippable)
            if let last = text.last { words[index].endsSentence = ".?!:".contains(last) }
        }

        var keep = [Bool](repeating: true, count: words.count)
        var lastKept = -1
        for index in words.indices {
            guard lastKept >= 0 else {
                lastKept = index
                continue
            }
            let previous = words[lastKept]
            let current = words[index]
            let previousCore = previous.core
            let currentCore = current.core

            let isSeamDuplicate =
                !previousCore.isEmpty && !currentCore.isEmpty
                && previousCore != currentCore
                && previousCore.lowercased() == currentCore.lowercased()
                && currentCore.first?.isLetter == true
                && !previous.endsSentence
                && current.startTimestamp - previous.startTimestamp <= overlapFrames

            guard isSeamDuplicate else {
                lastKept = index
                continue
            }

            // Keep the lower-cased copy; if neither is lower-case keep the
            // earlier (left-context) one.
            if currentCore == currentCore.lowercased(), previousCore != previousCore.lowercased() {
                keep[lastKept] = false
                lastKept = index
            } else {
                keep[index] = false
            }
        }

        var result: [TokenWindow] = []
        result.reserveCapacity(tokens.count)
        for index in words.indices where keep[index] {
            result.append(contentsOf: words[index].tokens)
        }
        return result
    }

    /// A piece is splice-safe when decoding it right after another word does
    /// not glue two words together: it either starts a new word (`▁`/space
    /// prefix) or is pure punctuation/symbols.
    private static func isSpliceSafePiece(_ piece: String) -> Bool {
        guard !piece.isEmpty else { return false }
        if isWordBoundary(piece) { return true }
        return piece.unicodeScalars.allSatisfy { scalar in
            CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }

    private func mergeChunks(_ left: [TokenWindow], _ right: [TokenWindow]) -> [TokenWindow] {
        if left.isEmpty { return right }
        if right.isEmpty { return left }

        let frameDuration = ASRConstants.secondsPerEncoderFrame
        let overlapDuration = overlapSeconds
        let halfOverlapWindow = overlapDuration / 2

        func startTime(of token: TokenWindow) -> Double {
            Double(token.timestamp) * frameDuration
        }

        func endTime(of token: TokenWindow) -> Double {
            startTime(of: token) + frameDuration
        }

        let leftEndTime = endTime(of: left.last!)
        let rightStartTime = startTime(of: right.first!)

        if leftEndTime <= rightStartTime {
            return left + right
        }

        let overlapLeft: [IndexedToken] = left.enumerated().compactMap { offset, token in
            let start = startTime(of: token)
            let end = start + frameDuration
            guard end > rightStartTime - overlapDuration else { return nil }
            return IndexedToken(index: offset, token: token, start: start, end: end)
        }

        let overlapRight: [IndexedToken] = right.enumerated().compactMap { offset, token in
            let start = startTime(of: token)
            guard start < leftEndTime + overlapDuration else { return nil }
            return IndexedToken(index: offset, token: token, start: start, end: start + frameDuration)
        }

        guard overlapLeft.count >= 2 && overlapRight.count >= 2 else {
            return mergeByMidpoint(
                left: left, right: right, leftEndTime: leftEndTime, rightStartTime: rightStartTime,
                frameDuration: frameDuration)
        }

        let minimumPairs = max(overlapLeft.count / 2, 1)

        let timeTolerantMatcher: (IndexedToken, IndexedToken) -> Bool = { [self] l, r in
            tokensMatch(l, r, tolerance: halfOverlapWindow)
        }

        // The longest contiguous run of matching tokens wins; LCS only when that run is too short.
        let contiguousMatches = SequenceMatcher.findContiguousMatches(
            left: overlapLeft,
            right: overlapRight,
            matcher: timeTolerantMatcher
        )

        // Convert SequenceMatch results to index pairs
        let contiguousPairs = contiguousMatches.map { ($0.leftStartIndex, $0.rightStartIndex) }

        if contiguousPairs.count >= minimumPairs {
            return mergeUsingMatches(
                matches: contiguousPairs,
                overlapLeft: overlapLeft,
                overlapRight: overlapRight,
                left: left,
                right: right
            )
        }

        let lcsMatches = SequenceMatcher.findLongestCommonSubsequence(
            left: overlapLeft,
            right: overlapRight,
            matcher: timeTolerantMatcher
        )

        guard !lcsMatches.isEmpty else {
            return mergeByMidpoint(
                left: left, right: right, leftEndTime: leftEndTime, rightStartTime: rightStartTime,
                frameDuration: frameDuration)
        }

        // Map LCS matches directly to pairs (no consolidation)
        // mergeUsingMatches requires one pair per matched element to function correctly
        let lcsPairs = lcsMatches.map { ($0.leftStartIndex, $0.rightStartIndex) }

        return mergeUsingMatches(
            matches: lcsPairs,
            overlapLeft: overlapLeft,
            overlapRight: overlapRight,
            left: left,
            right: right
        )
    }

    private func tokensMatch(_ left: IndexedToken, _ right: IndexedToken, tolerance: Double) -> Bool {
        guard tokenIdsMatch(left.token.token, right.token.token) else {
            return false
        }
        let timeDifference = abs(left.start - right.start)
        return timeDifference < tolerance
    }

    /// Token IDs match when equal or case-only variants of the same piece,
    /// so a falsely capitalized seam word still anchors.
    private func tokenIdsMatch(_ left: Int, _ right: Int) -> Bool {
        if left == right { return true }
        guard let caseVariantIds, let lhs = caseVariantIds[left], let rhs = caseVariantIds[right] else {
            return false
        }
        return lhs == rhs
    }

    private func mergeUsingMatches(
        matches: [(Int, Int)],
        overlapLeft: [IndexedToken],
        overlapRight: [IndexedToken],
        left: [TokenWindow],
        right: [TokenWindow]
    ) -> [TokenWindow] {
        let leftIndices = matches.map { overlapLeft[$0.0].index }
        let rightIndices = matches.map { overlapRight[$0.1].index }

        var result: [TokenWindow] = []

        if let firstLeft = leftIndices.first, firstLeft > 0 {
            result.append(contentsOf: left[..<firstLeft])
        }

        for idx in 0..<matches.count {
            let leftIndex = leftIndices[idx]
            let rightIndex = rightIndices[idx]

            result.append(left[leftIndex])

            guard idx < matches.count - 1 else { continue }

            let nextLeftIndex = leftIndices[idx + 1]
            let nextRightIndex = rightIndices[idx + 1]

            let gapLeft = nextLeftIndex > leftIndex + 1 ? Array(left[(leftIndex + 1)..<nextLeftIndex]) : []
            let gapRight = nextRightIndex > rightIndex + 1 ? Array(right[(rightIndex + 1)..<nextRightIndex]) : []

            if gapRight.count > gapLeft.count {
                result.append(contentsOf: gapRight)
            } else {
                result.append(contentsOf: gapLeft)
            }
        }

        if let lastRight = rightIndices.last, lastRight + 1 < right.count {
            let tail = right[(lastRight + 1)...]
            if let safeIds = spliceSafeTokenIds,
                let firstTail = tail.first,
                !safeIds.contains(firstTail.token)
            {
                // The splice lands mid-word: re-splice at a word boundary so
                // exactly one window segments the seam word.
                if let wordStart = wordInitialIndex(in: right, endingAt: lastRight, safeIds: safeIds),
                    popSeamWord(from: &result, safeIds: safeIds)
                {
                    // Right heard the seam word from its start: adopt its
                    // segmentation of the whole word.
                    result.append(contentsOf: right[wordStart...])
                } else {
                    // Right begins mid-word: left owns the seam word; resume
                    // right at its next word-initial piece instead of gluing.
                    if let lastLeft = leftIndices.last {
                        var cursor = lastLeft + 1
                        while cursor < left.count, !safeIds.contains(left[cursor].token) {
                            result.append(left[cursor])
                            cursor += 1
                        }
                    }
                    if let resume = tail.firstIndex(where: { safeIds.contains($0.token) }) {
                        result.append(contentsOf: tail[resume...])
                    } else {
                        // No word-initial piece in the tail: keep it verbatim,
                        // since a possible glue beats dropping a word.
                        result.append(contentsOf: tail)
                    }
                }
            } else {
                result.append(contentsOf: tail)
            }
        }

        return result
    }

    /// Index of the word-initial (or punctuation) piece starting the word
    /// that contains `anchor`, or nil when the stream begins mid-word.
    private func wordInitialIndex(
        in stream: [TokenWindow],
        endingAt anchor: Int,
        safeIds: Set<Int>
    ) -> Int? {
        var index = anchor
        while index >= 0 {
            if safeIds.contains(stream[index].token) { return index }
            index -= 1
        }
        return nil
    }

    /// Remove the trailing seam word from `result` so the right window's
    /// segmentation can replace it; false (untouched) when `result` has no
    /// word-initial piece. The scan is unbounded: a piece cap would miss long seam words.
    private func popSeamWord(from result: inout [TokenWindow], safeIds: Set<Int>) -> Bool {
        var cursor = result.count - 1
        while cursor >= 0 {
            if safeIds.contains(result[cursor].token) {
                result.removeLast(result.count - cursor)
                return true
            }
            cursor -= 1
        }
        return false
    }

    private func mergeByMidpoint(
        left: [TokenWindow],
        right: [TokenWindow],
        leftEndTime: Double,
        rightStartTime: Double,
        frameDuration: Double
    ) -> [TokenWindow] {
        let cutoff = (leftEndTime + rightStartTime) / 2
        // Token streams are emitted in timestamp order, so the cutoff filter
        // is equivalent to a prefix/suffix split.
        var leftEnd = left.firstIndex { Double($0.timestamp) * frameDuration >= cutoff } ?? left.count
        var rightStart = right.firstIndex { Double($0.timestamp) * frameDuration >= cutoff } ?? right.count
        if let safeIds = spliceSafeTokenIds {
            // A pure time cutoff can split a word: let left finish its word, and
            // drop orphaned continuation pieces from right.
            if leftEnd > 0 {
                while leftEnd < left.count, !safeIds.contains(left[leftEnd].token) {
                    leftEnd += 1
                }
            }
            // Adopt the advanced cutoff only if a splice-safe token exists ahead,
            // otherwise the whole right window would be discarded; fall back to
            // the cutoff-based split.
            var scanIndex = rightStart
            while scanIndex < right.count, !safeIds.contains(right[scanIndex].token) {
                scanIndex += 1
            }
            if scanIndex < right.count {
                rightStart = scanIndex
            }
        }
        return Array(left[..<leftEnd]) + Array(right[rightStart...])
    }

    private struct IndexedToken {
        let index: Int
        let token: TokenWindow
        let start: Double
        let end: Double
    }
}

/// The match type and the two matchers `SeamMerge` uses, from FluidAudio's
/// SequenceMatch.swift and SequenceMatcher.swift.
private struct SequenceMatch {
    let leftStartIndex: Int
    let rightStartIndex: Int
    let length: Int
}

private struct SequenceMatcher<Element> {
    /// Find longest contiguous matching sequence.
    ///
    /// Searches for the longest run of consecutive matches between two sequences.
    /// Unlike LCS, this requires matches to be adjacent in both sequences.
    ///
    /// - Returns: Array of single-element matches forming the longest contiguous run
    static func findContiguousMatches(
        left: [Element],
        right: [Element],
        matcher: (Element, Element) -> Bool
    ) -> [SequenceMatch] {
        var best: [SequenceMatch] = []

        for i in 0..<left.count {
            for j in 0..<right.count {
                if matcher(left[i], right[j]) {
                    var current: [SequenceMatch] = []
                    var k = i
                    var l = j

                    while k < left.count && l < right.count {
                        if matcher(left[k], right[l]) {
                            current.append(
                                SequenceMatch(
                                    leftStartIndex: k,
                                    rightStartIndex: l,
                                    length: 1
                                ))
                            k += 1
                            l += 1
                        } else {
                            break
                        }
                    }

                    if current.count > best.count {
                        best = current
                    }
                }
            }
        }

        return best
    }

    /// Find longest common subsequence using dynamic programming.
    ///
    /// Returns all matching positions found via LCS algorithm. This allows
    /// non-contiguous matches and is useful when sequences might have
    /// insertions or deletions.
    ///
    /// - Returns: Array of single-element matches, one per matched pair
    static func findLongestCommonSubsequence(
        left: [Element],
        right: [Element],
        matcher: (Element, Element) -> Bool
    ) -> [SequenceMatch] {
        let leftCount = left.count
        let rightCount = right.count

        var dp = Array(repeating: Array(repeating: 0, count: rightCount + 1), count: leftCount + 1)

        // Build DP table
        for i in 1...leftCount {
            for j in 1...rightCount {
                if matcher(left[i - 1], right[j - 1]) {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find matches
        var matches: [SequenceMatch] = []
        var i = leftCount
        var j = rightCount

        while i > 0 && j > 0 {
            if matcher(left[i - 1], right[j - 1]) {
                // Match found - create single-element match
                matches.append(
                    SequenceMatch(
                        leftStartIndex: i - 1,
                        rightStartIndex: j - 1,
                        length: 1
                    ))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return matches.reversed()
    }
}
