public import Foundation
public import LexiconDomain
import Security
import Synchronization

/// Sole owner of UserDefaults. Modules never read settings themselves: the
/// Conductor snapshots `Preferences` once per Dictation and passes values down.
/// Launch arguments override (`open ... --args -microphone <uid>`), via the
/// UserDefaults argument domain.
public final class PreferencesStore: Sendable {
    private struct State {
        /// What is saved on disk, or the caller's value for a fixed store.
        var saved: Preferences
        /// `-microphone <uid>` for this run only. Never saved, so it can't stick.
        let microphone: String?
        var subscribers: [UUID: AsyncStream<Preferences>.Continuation] = [:]

        var effective: Preferences {
            var preferences = saved
            if let microphone { preferences.microphoneUID = microphone }
            return preferences
        }
    }

    private let state: Mutex<State>
    // nil for a fixed store, which never writes. UserDefaults is documented thread-safe, just not marked Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults?

    public init(defaults: UserDefaults = .standard) {
        state = Mutex(State(saved: Self.load(from: defaults), microphone: defaults.string(forKey: "microphone")))
        self.defaults = defaults
    }

    /// Headless runs: the caller's settings for the whole run, never written anywhere.
    init(fixed preferences: Preferences) {
        state = Mutex(State(saved: preferences, microphone: nil))
        defaults = nil
    }

    public func snapshot() -> Preferences { state.withLock { $0.effective } }

    /// Settings window and onboarding. Publishes to `changes`.
    public func update(_ change: (inout Preferences) -> Void) {
        state.withLock { state in
            change(&state.saved)
            if let defaults = self.defaults, let data = Self.encode(state.saved) { defaults.set(data, forKey: Self.key) }
            let effective = state.effective
            for subscriber in state.subscribers.values { subscriber.yield(effective) }
        }
    }

    /// Each call is a new stream (any number of observers). Only the newest value
    /// is buffered: a slow observer catches up to the current setting, not a backlog.
    public func changes() -> AsyncStream<Preferences> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Preferences>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Weak: a stream that is never cancelled must not keep the store alive.
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.state.withLock { $0.subscribers[id] = nil }
        }
        state.withLock { $0.subscribers[id] = continuation }
        return stream
    }

    private static let key = "preferences"

    /// JSON with an explicit null for every nil setting. The encoder leaves nil
    /// out, and `load` would read a missing key as "keep the default", so a
    /// setting Jake cleared (no local model) would come back.
    private static func encode(_ preferences: Preferences) -> Data? {
        guard let data = try? JSONEncoder().encode(preferences),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences.defaults)) as? [String: Any]
        else { return nil }
        for key in all.keys where object[key] == nil { object[key] = NSNull() }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// Defaults first, then every stored key, so a field added in a later version
    /// keeps its default and the other stored settings survive. Anything unreadable
    /// falls back to the defaults.
    private static func load(from defaults: UserDefaults) -> Preferences {
        guard let stored = defaults.data(forKey: key),
              let storedObject = try? JSONSerialization.jsonObject(with: stored) as? [String: Any],
              let defaultObject = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences.defaults)) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaultObject.merging(storedObject) { _, new in new }),
              let preferences = try? JSONDecoder().decode(Preferences.self, from: merged)
        else { return Preferences.defaults }
        return preferences
    }
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
