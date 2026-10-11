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

    /// Prefixes that real providers put on their keys. The rest of the key must
    /// still look random (`hasRandomBody`), so "sk-learn" alone doesn't match.
    static let keyPrefixes = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "whsec_",
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-",
        "xoxa-", "xoxb-", "xoxe-", "xoxp-", "xoxr-", "xoxs-",
        "AKIA", "ASIA", "AIza", "SG.", "hf_", "npm_", "xai-", "gsk_", "pplx-", "r8_", "shpat_", "dop_v1_",
    ]

    /// Generic keys without a known prefix: a run of letters and digits this long
    /// that doesn't read as words. Random base62 of this length is caught about
    /// 98% of the time; camelCase names and words with a year are not.
    static let randomRunLength = 24

    private static func isTokenScalar(_ s: Unicode.Scalar) -> Bool {
        s.isASCII && (s.properties.isAlphabetic || ("0"..."9").contains(s) || "_-+/=.".unicodeScalars.contains(s))
    }

    private static func isKeyShaped(_ raw: String) -> Bool {
        let token = raw.trimmingDots
        for prefix in keyPrefixes where token.hasPrefix(prefix) {
            let body = token.dropFirst(prefix.count)
            if body.count >= 16, body.contains(where: \.isNumber), body.contains(where: \.isLetter) { return true }
        }
        let parts = token.split(separator: ".")
        if token.hasPrefix("eyJ"), parts.count >= 3, parts.prefix(2).allSatisfy({ $0.count >= 10 }) { return true }  // JWT
        return token.split { !($0.isLetter || $0.isNumber || $0 == "+" || $0 == "=") }.contains { run in
            run.count >= randomRunLength && run.contains(where: \.isNumber) && run.contains(where: \.isLetter)
                && !readsAsWords(run)
        }
    }

    /// Half or more of the run sits in lowercase stretches of four letters or more:
    /// `HeadlessDictationTests2024`, not `x9Kq2mVb7RtL4wZp`.
    private static func readsAsWords(_ run: Substring) -> Bool {
        var inWords = 0, stretch = 0
        for c in run {
            if c.isLowercase { stretch += 1; continue }
            if stretch >= 4 { inWords += stretch }
            stretch = 0
        }
        if stretch >= 4 { inWords += stretch }
        return inWords * 2 >= run.count
    }

    static let passwordWords: Set<String> = ["password", "passcode", "passphrase"]

    /// Words that, right after "password is", say something about the password
    /// rather than being it: "my password is wrong", "the password is in the Keychain".
    static let notAPassword: Set<String> = [
        "a", "also", "always", "an", "and", "asked", "at", "bad", "being", "blank", "but", "case", "changed",
        "compromised", "correct", "different", "easy", "empty", "encrypted", "entered", "expired", "fine", "for",
        "generated", "getting", "good", "hard", "hashed", "here", "hidden", "how", "in", "incorrect", "insecure",
        "invalid", "it", "just", "kept", "leaked", "like", "long", "managed", "mandatory", "missing", "my", "needed",
        "never", "nothing", "now", "of", "ok", "okay", "on", "only", "optional", "or", "our", "probably", "protected",
        "really", "required", "reset", "reused", "right", "rotated", "same", "saved", "secure", "sent", "set", "short",
        "shown", "simple", "so", "something", "still", "stored", "strong", "that", "the", "their", "there", "this",
        "to", "too", "typed", "unique", "used", "usually", "very", "visible", "weak", "what", "when", "where", "why",
        "wrong", "your",
    ]

    /// "my password is hunter2", "passcode's 4821", "password: tangerine".
    private static func statesAPassword(_ text: String) -> Bool {
        let words = text.lowercased()
            .replacing("\u{2019}", with: "'").replacing(":", with: " is ").replacing("=", with: " is ")
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .init(charactersIn: ".,;!?\"()[]{}")) }
            .filter { !$0.isEmpty }
        for (i, word) in words.enumerated() {
            var value = i + 2
            if word.hasSuffix("'s"), passwordWords.contains(String(word.dropLast(2))) {
                value = i + 1
            } else if !passwordWords.contains(word) || i + 1 == words.count || !["is", "was"].contains(words[i + 1]) {
                continue
            }
            guard value < words.count else { continue }
            let said = words[value].trimmingCharacters(in: .init(charactersIn: "'"))
            if !said.isEmpty, !notAPassword.contains(said) { return true }
        }
        return false
    }
}

private extension String {
    var trimmingDots: Substring {
        let start = firstIndex { $0 != "." } ?? endIndex
        let end = lastIndex { $0 != "." }.map(index(after:)) ?? start
        return self[start..<max(start, end)]
    }
}
