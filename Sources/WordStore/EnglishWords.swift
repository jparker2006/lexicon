import Foundation

/// Which words count as plain English for folding: a run of words that are all
/// plain English never folds into a Term (`RuleSet`).
///
/// The judge is the system word list, `/usr/share/dict/words` (Webster's 1934,
/// on every Mac, so it costs no bytes), plus the everyday words it predates.
/// It lists headwords only, so a word also counts when stripping a plural or
/// verb ending leaves one ("trees", "pushed", "running"). Single letters other
/// than "a" and "i" are spelled-out letters, not words ("G stack").
///
/// Erring toward English only costs a fold, which a Rule can add back; erring
/// the other way rewrites a sentence. So when the list is missing, every word
/// counts as English and nothing folds.
enum EnglishWords {
    static let systemList = URL(filePath: "/usr/share/dict/words")

    /// Everyday words newer than the list. Jargon stays out ("repo", "auth"):
    /// it is rarely plain English, and counting it would stop folds like
    /// "auth zero" to Auth0.
    static let modern: Set<String> = [
        "app", "backend", "blog", "chatbot", "database", "debug", "demo", "download", "email", "emoji", "frontend",
        "hashtag", "homepage", "inbox", "info", "internet", "laptop", "livestream", "logout", "offline", "ok",
        "okay", "online", "podcast", "selfie", "signup", "smartphone", "startup", "username", "website", "wifi",
        "workflow",
    ]

    /// The words of `candidates` (lowercased) that are plain English. Reads the
    /// list once, about 10 ms, so it runs when the Lexicon changes, never per Dictation.
    static func among(_ candidates: Set<String>, list: URL = systemList) -> Set<String> {
        var english = Set<String>()
        var wanted: [String: [String]] = [:]  // headword -> the candidates it makes English
        for word in candidates where word.count > 1 || word == "a" || word == "i" {
            for head in headwords(of: word) {
                if modern.contains(head) { english.insert(word) } else { wanted[head, default: []].append(word) }
            }
        }
        guard !wanted.isEmpty else { return english }
        guard let data = try? Data(contentsOf: list, options: .alwaysMapped) else { return candidates }

        // One pass over 2.5 MB: hash each line in place instead of making 236,000 Strings.
        let byHash = Dictionary(grouping: wanted.keys, by: { fnv($0.utf8) })
        data.withUnsafeBytes { bytes in
            var start = 0
            var hash = fnvBasis
            for (index, byte) in bytes.enumerated() {
                guard byte == UInt8(ascii: "\n") else {
                    hash = (hash ^ UInt64(byte)) &* fnvPrime
                    continue
                }
                for head in byHash[hash] ?? [] where head.utf8.elementsEqual(bytes[start..<index]) {
                    english.formUnion(wanted[head] ?? [])
                }
                start = index + 1
                hash = fnvBasis
            }
        }
        return english
    }

    /// `word`, and the headwords a plural or verb ending may hide.
    static func headwords(of word: String) -> [String] {
        var heads = [word]
        func strip(_ suffix: String, adding tail: String = "") {
            guard word.hasSuffix(suffix), word.count > suffix.count + 1 else { return }
            let stem = word.dropLast(suffix.count)
            heads.append(String(stem) + tail)
            // "running" -> "run", "stopped" -> "stop"
            if suffix == "ing" || suffix == "ed", tail.isEmpty, let last = stem.last, stem.dropLast().last == last {
                heads.append(String(stem.dropLast()))
            }
        }
        strip("s")
        strip("es")
        strip("ies", adding: "y")
        strip("d")
        strip("ed")
        strip("ing")
        strip("ing", adding: "e")
        return heads
    }

    private static let fnvBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvPrime: UInt64 = 0x100_0000_01b3

    private static func fnv(_ bytes: some Sequence<UInt8>) -> UInt64 {
        bytes.reduce(fnvBasis) { ($0 ^ UInt64($1)) &* fnvPrime }
    }
}
