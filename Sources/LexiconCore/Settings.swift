public import Foundation
public import LexiconDomain

/// Sole owner of UserDefaults. Modules never read settings themselves: the
/// Conductor snapshots `Preferences` once per Dictation and passes values down.
/// Launch arguments override (`open ... --args -microphone <uid>`), via the
/// UserDefaults argument domain.
public final class PreferencesStore: @unchecked Sendable {
    public init(defaults: UserDefaults = .standard) { fatalError("not implemented") }

    public func snapshot() -> Preferences { fatalError("not implemented") }

    /// Settings window and onboarding. Publishes to `changes`.
    public func update(_ change: (inout Preferences) -> Void) { fatalError("not implemented") }

    public func changes() -> AsyncStream<Preferences> { fatalError("not implemented") }
}

/// API keys in the Keychain (#8): generic passwords, service = bundle id,
/// account = `CredentialID.account`. Read once, cached in memory.
/// Headless runs (`lexicon-eval`) read `LEXICON_KEY_<ACCOUNT>` environment
/// variables instead, since the Keychain item's ACL belongs to the app.
public final class Secrets: @unchecked Sendable {
    public enum Source: Sendable { case keychain(service: String), environment }

    public init(_ source: Source) { fatalError("not implemented") }

    /// Handed to `CloudAccess.granted(by:app:keys:)`.
    public var lookup: @Sendable (CredentialID) -> String? { fatalError("not implemented") }

    public func set(_ value: String?, for id: CredentialID) throws { fatalError("not implemented") }
}
