import Foundation

/// The Secret guard (#5): a local check, microseconds, that finds API keys,
/// tokens, passwords and similar in text before it leaves the Mac. A match keeps
/// the whole Dictation local-only (`CloudAccess.key(_:sending:)` revokes).
///
/// Limit: speech streams audio while Jake talks, so a spoken secret reaches the
/// speech provider before any text exists to check. The guard protects every
/// text call and cuts the rest of the stream (Transcription checks each finalized
/// segment); it cannot recall audio already sent.
///
/// Starting rules, to be tuned on the Test set: a false positive costs one
/// Dictation its AI cleanup, a false negative leaks a secret, so the rules lean
/// toward matching anything shaped like a key.
public enum SecretGuard {
    public static func matches(_ text: String) -> Bool {
        if text.contains("PRIVATE KEY-----") { return true }
        let tokens = text.unicodeScalars.split { !isTokenScalar($0) }.map(String.init)
        return tokens.contains(where: isKeyShaped) || statesAPassword(text)
    }

    /// Prefixes that real providers put on their keys. The rest must still look
    /// random, so `sk-architecture-review-2026` doesn't match.
    static let keyPrefixes = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "whsec_",
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-",
        "xoxa-", "xoxb-", "xoxe-", "xoxp-", "xoxr-", "xoxs-",
        "AKIA", "ASIA", "AIza", "SG.", "hf_", "npm_", "xai-", "gsk_", "pplx-", "r8_", "shpat_", "dop_v1_",
    ]

    /// Keys without a known prefix: a stretch between dots this long, with letters
    /// and digits, or varied lowercase letters with long consonant runs, that
    /// doesn't read as words.
    static let randomRunLength = 24

    private static func isTokenScalar(_ s: Unicode.Scalar) -> Bool {
        s.isASCII && (s.properties.isAlphabetic || ("0"..."9").contains(s) || "_-+/=.".unicodeScalars.contains(s))
    }

    private static func isKeyShaped(_ raw: String) -> Bool {
        let token = raw.trimmingDots
        for prefix in keyPrefixes where token.hasPrefix(prefix) {
            if looksRandom(token.dropFirst(prefix.count), length: 16, knownPrefix: true) { return true }
        }
        let parts = token.split(separator: ".")
        if token.hasPrefix("eyJ"), parts.count >= 3, parts.prefix(2).allSatisfy({ $0.count >= 10 }) { return true }  // JWT
        return parts.contains { looksRandom($0, length: randomRunLength) }
    }

    private static func looksRandom(_ run: Substring, length: Int, knownPrefix: Bool = false) -> Bool {
        guard run.count >= length else { return false }
        if run.allSatisfy(\.isLowercase) {
            // A provider prefix already signals a key. Without one, ordinary
            // lowercase words also need a consonant stretch to look random.
            guard Set(run).count >= 12 else { return false }
            if knownPrefix { return true }
            var consonants = 0
            for letter in run {
                consonants = "aeiouy".contains(letter) ? 0 : consonants + 1
                if consonants >= 6 { return true }
            }
            return false
        }
        return run.contains(where: \.isNumber) && run.contains(where: \.isLetter) && !readsAsWords(run)
    }

    /// Half or more of the run is words: three or more lowercase letters, with the
    /// capital before them. `AVAudioEngineInputNodeTap16kHz` and
    /// `issue-65-keys-and-cloud-access` read as words; `x9Kq2mVb7RtL4wZp` doesn't.
    private static func readsAsWords(_ run: Substring) -> Bool {
        var inWords = 0, lower = 0, capital = 0
        for c in run {
            if c.isLowercase { lower += 1; continue }
            if lower >= 3 { inWords += lower + capital }
            lower = 0
            capital = c.isUppercase ? 1 : 0
        }
        if lower >= 3 { inWords += lower + capital }
        return inWords * 2 >= run.count
    }

    /// Words whose value is a secret when one follows: "my password is hunter2".
    static let passwordWords: Set<String> = ["password", "passcode", "passphrase", "passwd"]
    /// Weaker words that often precede ordinary prose ("the secret is to..."), so
    /// they count only when the value has a digit: "the client secret is 9fK2mLp7".
    static let secretWords: Set<String> = ["secret", "token", "pin"]

    /// Words that, as the value, say something about the password rather than
    /// being it: "my password is wrong", "the password is in the Keychain",
    /// "password: String". Words ending in -ed, -ing and -ly are skipped too.
    static let notAPassword: Set<String> = [
        "a", "also", "an", "and", "at", "bad", "blank", "but", "case", "correct", "different", "easy", "empty",
        "false", "fine", "for", "from", "gone", "good", "hard", "here", "how", "in", "incorrect", "insecure",
        "invalid", "it", "just", "kept", "like", "long", "my", "nil", "no", "none", "not", "now", "null", "of",
        "ok", "okay", "on", "optional", "or", "our", "read", "required", "reset", "right", "same", "secure", "sent",
        "set", "short", "shown", "simple", "so", "something", "still", "string", "strong", "that", "the", "their",
        "there", "this", "to", "too", "true", "undefined", "unique", "valid", "very", "visible", "weak", "what",
        "when", "where", "why", "written", "wrong", "your",
    ]

    /// "my password is hunter2", "the password for the server is hunter2",
    /// "passcode's 4821", "passphrase: tangerine", "the API token is 9fK2mLp7".
    private static func statesAPassword(_ text: String) -> Bool {
        let normalized = text.lowercased().replacing("\u{2019}", with: "'").replacing("==", with: " equals-op ")
            .replacing(":", with: " is ").replacing("=", with: " is ")
        var words: [(text: String, raw: Substring, endsSentence: Bool)] = []
        for raw in normalized.split(whereSeparator: \.isWhitespace) {
            let word = raw.trimmingCharacters(in: .init(charactersIn: ".,;!?\"()[]{}"))
            if !word.isEmpty { words.append((word, raw, raw.last.map { ".!?".contains($0) } ?? false)) }
        }
        for (i, word) in words.enumerated() {
            if word.text.hasSuffix("'s"), passwordWords.contains(String(word.text.dropLast(2))) {
                if i + 1 < words.count, hasDigitOrSymbol(words[i + 1].text) { return true }
                continue
            }
            let strong = passwordWords.contains(word.text)
            guard strong || secretWords.contains(word.text), !word.endsSentence else { continue }
            // The verb may come a few words later: "the password for the server is ...".
            for j in (i + 1)..<min(i + 7, words.count) {
                guard ["is", "was", "equals"].contains(words[j].text) else {
                    if words[j].endsSentence { break }
                    continue
                }
                guard !words[j].endsSentence, j + 1 < words.count else { break }
                let value = words[j + 1].text.trimmingCharacters(in: .init(charactersIn: "'"))
                if words[j + 1].raw.contains("(") { break }  // code: `password = keychain.read()`
                if strong ? isPasswordValue(value) : value.count >= 4 && value.contains(where: \.isNumber) { return true }
                break
            }
        }
        return false
    }

    private static func isPasswordValue(_ value: String) -> Bool {
        if value.isEmpty { return false }
        if hasDigitOrSymbol(value) { return true }
        return !notAPassword.contains(value) && !["ed", "ing", "ly"].contains(where: value.hasSuffix)
    }

    private static func hasDigitOrSymbol(_ value: String) -> Bool {
        value.contains { !$0.isLetter && $0 != "'" && $0 != "-" }
    }
}

private extension String {
    var trimmingDots: Substring {
        let start = firstIndex { $0 != "." } ?? endIndex
        let end = lastIndex { $0 != "." }.map(index(after:)) ?? start
        return self[start..<max(start, end)]
    }
}
