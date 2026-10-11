public import Foundation
public import LexiconDomain
import Security
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
/// account = `CredentialID.account`. Each key is read once, on first use, and
/// kept in memory (a missing key too, until `set` stores one). A read that
/// fails, such as a denied Keychain prompt, is not kept: the next call asks again.
/// Headless runs (`lexicon-eval`) read `LEXICON_KEY_<ACCOUNT>` environment
/// variables instead, since the Keychain item's ACL belongs to the app.
/// Nothing here logs: a key never reaches a log, an error message or History.
public final class Secrets: Sendable {
    public enum Source: Sendable { case keychain(service: String), environment }

    let source: Source
    private let cache = Mutex<[CredentialID: String?]>([:])

    public init(_ source: Source) { self.source = source }

    /// Handed to `CloudAccess.granted(by:app:keys:)`. Called only when a cloud
    /// call needs its key, never at fn-down.
    public var lookup: @Sendable (CredentialID) -> String? {
        switch source {
        case .keychain(let service): { [self] id in
            if let known = cache.withLock({ $0[id] }) { return known }
            // Read outside the lock: the first read can wait on a Keychain prompt.
            let key: String?
            switch Keychain.read(service: service, account: id.account) {
            case .found(let value): key = value
            case .missing: key = nil
            case .failed: return nil
            }
            // A `set` that landed during the read wins over what the read saw.
            return cache.withLock { cache in
                if let newer = cache[id] { return newer }
                cache[id] = key
                return key
            }
        }
        case .environment: { ProcessInfo.processInfo.environment[Secrets.environmentName(for: $0)] }
        }
    }

    /// `LEXICON_KEY_` plus the Keychain account, upper case, `.` and `-` as `_`:
    /// `cleanup.openrouter` is `LEXICON_KEY_CLEANUP_OPENROUTER`.
    static func environmentName(for id: CredentialID) -> String {
        "LEXICON_KEY_" + String(id.account.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    /// Settings: stores `value` in the Keychain, or deletes the item for nil, and
    /// the next lookup returns it without a restart.
    public func set(_ value: String?, for id: CredentialID) throws(KeychainError) {
        guard case .keychain(let service) = source else { throw .readOnly }
        try Keychain.write(value, service: service, account: id.account)
        cache.withLock { $0[id] = value }
    }
}

public enum KeychainError: Error, Equatable {
    /// `lexicon-eval`'s keys come from its environment.
    case readOnly
    /// The Security framework's status code, never the key.
    case failed(OSStatus)
}

/// Login Keychain generic passwords. The only Security importer (scripts/check-imports.swift).
private enum Keychain {
    enum Read { case found(String), missing, failed }

    static func read(service: String, account: String) -> Read {
        var query = item(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed }
            let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? .missing : .found(key)
        case errSecItemNotFound: return .missing
        default: return .failed
        }
    }

    /// Updates in place when the item exists, so the apps Jake already allowed
    /// to read it (Keychain "Always Allow") keep reading it without a prompt.
    static func write(_ value: String?, service: String, account: String) throws(KeychainError) {
        let query = item(service: service, account: account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw .failed(status) }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw .failed(status) }
    }

    private static func item(service: String, account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}
