import Testing
import LexiconDomain

// Every value here is fake: made up for the test in the shape of a real key.
// Each prefix is split from its body so secret scanners don't flag the file.

@Test(arguments: [
    "sk-ant-api03-" + "Zq8vT2mWc4LpX9rB7nKd1sYhF6gJ0eAu",
    "sk-proj-" + "4fGh7Jk2Lm9Np3Qr8St1Uv6Wx0Yz5AbCdEf",
    "sk-or-v1-" + "9f2c4e6a8b0d1f3e5a7c9b2d4f6e8a0c1b3d5f7e9a2c4b6d8f0e1a3c5b7d9f2e",
    "sk_live_" + "51HxQ2eL8mVn3Kp7RtYw0Zs4Ab",
    "rk_test_" + "9Qw2Er4Ty6Ui8Op0As3Df5Gh",
    "ghp_" + "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xY2zA4",
    "github_pat_" + "11AQ7XW3PLM0Zt9Rb4Vn_Kd8sYhF6gJ0eAuX2cW5mN7pL1qT",
    "xoxb-" + "2048-4096-Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2",
    "AKIA" + "Q7XW3PLMZ9TR4VNB",
    "AIza" + "SyB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xY2z",
    "glpat-" + "xY7wV6uT5sR4qP3oN2mL",
    "hf_" + "Qw2Er4Ty6Ui8Op0As3Df5Gh7Jk9Lz",
    "SG." + "a1B2c3D4e5F6g7H8i9J0kL.mN1oP2qR3sT4uV5wX6yZ7aB8cD9eF0gH1iJ2kL3",
    "eyJhbGciOiJIUzI1NiJ9." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk",
    "x9Kq2mVb7RtL4wZp8NcY3hJd6FsA1gUe",
    "3f9a1c7e5b2d8f4a6c0e9b1d7f3a5c8e2b4d6f0a",
    "-----BEGIN OPENSSH " + "PRIVATE KEY-----",
    "wJalrXUtnFEMI/K7MDENG/" + "bPxRfiCYEXAMPLEKEY",
    "a7Kp2Lm9Qr4Ts1Vw8Xb_" + "3Nc6Hd0Jf5Gz7Yu2Ei",
])
func knownKeyShapesMatch(_ secret: String) {
    #expect(SecretGuard.matches(secret))
    #expect(SecretGuard.matches("Here's the key \(secret), can you put it in the env file?"))
}

@Test(arguments: [
    "qjvmxkztbdrphwnslfygcauo",
    "mzrkwxjtpvhdqgcfnblyaose",
    "vndqrxjklpwmztbfhgcyaose",
])
func lowercaseRandomShapedSecretsMatch(_ secret: String) {
    #expect(SecretGuard.matches(secret))
    #expect(SecretGuard.matches("Please add \(secret) to the private config."))
}

@Test func lowercaseHuggingFaceKeyMatchesAloneAndInProse() {
    let secret = "hf_" + "kqvxeimzjraupodl"

    #expect(SecretGuard.matches(secret))
    #expect(SecretGuard.matches("Keep this Hugging Face token private: \(secret)."))
}

@Test(arguments: [
    "my password is hunter2",
    "The password is purple monkey dishwasher.",
    "OK so the passcode's 4821, write that down",
    "passphrase: tangerine",
    "Password = Swordfish99",
    "the password for the server is hunter2",
    "The password I use for GitHub is tr0ub4dor&3",
    "the password equals hunter2",
    "passwd is hunter2",
    "The client secret is 9fK2mLp7Qr4Tz1Xc",
    "my PIN is 4821",
])
func passwordPhrasesMatch(_ text: String) {
    #expect(SecretGuard.matches(text))
}

@Test(arguments: [
    "Can you refactor the useAuth hook so it doesn't re-render on every keystroke?",
    "The meeting moved to 3:45 on 2026-10-11, call me at 555-123-4567.",
    "We sold 1,250,000 units in Q3 and revenue grew 12.5% to $48.7 million.",
    "Order #A1234 shipped; tracking number 1Z999AA10123456784 arrives Tuesday.",
    "Bump FluidAudio to 0.7.2 and jev-1.13.0, then rerun lexicon-eval on issue 65.",
    "Look at github.com/jparker2006/lexicon/issues/36 for the spec.",
    "Open Sources/LexiconDomain/Preferences.swift and Tests/LexiconTests/HeadlessDictationTests.swift.",
    "The API key is in the Keychain, and the token expires in 3600 seconds.",
    "My password is wrong again, can you reset it?",
    "The password is stored in the Keychain, not in the env file.",
    "Is the passcode required on the second screen?",
    "Make sure the password's column is nullable.",
    "The password's hash is stored in the users table.",
    "The password is not in the repo, so use the Keychain.",
    "The password is read from the environment and is no longer valid after a day.",
    "let password = keychain.read()",
    "let cloudcredential = secrets.lookup(model)",
    "Add a password: String field to the User struct, and if password == null return early.",
    "The secret is to keep the token short, about 3 words.",
    "the secret is to keep the token short, about 3 words",
    "Reset my password. It is 2026 after all.",
    "Rename AVAudioEngineInputNodeTap16kHz and NSURLSessionDataTaskV2Request.",
    "Try sk-architecture-review-2026, xai-grok-code-fast-1 and hf_whisper_large_v3_turbo_mlx.",
    "Push feature/issue-65-keys-and-cloud-access and claude_issue_65_keys_cloud_access_v2.",
    "Supercalifragilisticexpialidocious, internationalization, and antidisestablishmentarianism.",
    "Commit e3aad6c fixed the race; the next one is 98b609a.",
    "I'll get 2x the throughput with 16 kHz mono at 48000 samples per 3 seconds.",
    "",
])
func ordinaryProseDoesNotMatch(_ text: String) {
    #expect(!SecretGuard.matches(text))
}
