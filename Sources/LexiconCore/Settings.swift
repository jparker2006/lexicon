public import Foundation
public import LexiconDomain
import Synchronization

/// Sole owner of UserDefaults. Modules never read settings themselves: the
/// Conductor snapshots `Preferences` once per Dictation and passes values down.
/// Launch arguments override (`open ... --args -microphone <uid>`), via the
/// UserDefaults argument domain.
public final class PreferencesStore: Sendable {
    private let current: Mutex<Preferences>

    public init(defaults: UserDefaults = .standard) { fatalError("not implemented") }

    /// Headless runs: the caller's settings for the whole run, never written anywhere.
    init(fixed preferences: Preferences) { current = Mutex(preferences) }

    public func snapshot() -> Preferences { current.withLock { $0 } }

    /// Settings window and onboarding. Publishes to `changes`.
    public func update(_ change: (inout Preferences) -> Void) { fatalError("not implemented") }

    public func changes() -> AsyncStream<Preferences> { fatalError("not implemented") }
}

/// API keys in the Keychain (#8): generic passwords, service = bundle id,
/// account = `CredentialID.account`. Read once, cached in memory.
/// Headless runs (`lexicon-eval`) read `LEXICON_KEY_<ACCOUNT>` environment
/// variables instead, since the Keychain item's ACL belongs to the app.
public final class Secrets: Sendable {
    public enum Source: Sendable { case keychain(service: String), environment }

    let source: Source

    public init(_ source: Source) { self.source = source }

    /// Handed to `CloudAccess.granted(by:app:keys:)`. Called only when a cloud
    /// call needs its key, never at fn-down.
    public var lookup: @Sendable (CredentialID) -> String? {
        switch source {
        case .keychain: { _ in fatalError("not implemented") }
        case .environment: { ProcessInfo.processInfo.environment[Secrets.environmentName(for: $0)] }
        }
    }

    /// `LEXICON_KEY_` plus the Keychain account, upper case, `.` and `-` as `_`:
    /// `cleanup.openrouter` is `LEXICON_KEY_CLEANUP_OPENROUTER`.
    static func environmentName(for id: CredentialID) -> String {
        "LEXICON_KEY_" + String(id.account.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    public func set(_ value: String?, for id: CredentialID) throws { fatalError("not implemented") }
}
