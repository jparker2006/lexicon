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

extension PreferencesStore {
    /// Model install for the app with this bundle id, from that app's saved settings:
    /// nil while Private mode is on in it, so the download opens no connection.
    /// Only reads them: `lexicon-eval --install-model` runs outside the app.
    public static func modelInstallAccess(forApp bundleID: String) -> CloudAccess? {
        guard let defaults = UserDefaults(suiteName: bundleID) else { return nil }
        return CloudAccess.granted(by: PreferencesStore(defaults: defaults).snapshot(), for: .modelInstall,
                                   keys: { _ in nil })
    }
}

/// How a credential appears in Settings. This reports storage only, never
/// whether a provider accepts the key.
public enum CredentialAvailability: Sendable, Equatable {
    case saved
    case missing
    case unavailable
}

/// The only requests Settings may make of the credential owner.
public enum CredentialEdit: Sendable {
    case availability(CredentialID)
    case save(CredentialID, String)
    case remove(CredentialID)
}

/// Bounded results for Settings. Key material never comes back through this API.
public enum CredentialOutcome: Sendable, Equatable {
    case availability(CredentialAvailability)
    case saved
    case removed
    case emptyEntry
    case refused
    case unavailable
}

public typealias CredentialCommand = @Sendable (
    CredentialEdit, @escaping @Sendable (CredentialOutcome) -> Void
) -> Void

#if DEBUG
public enum SettingsFixtureAction: Sendable { case begin, inspect, end }

public struct SettingsFixtureObservation: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, reserved, refused, owned, removed, stranded }
    public enum Outcome: Sendable, Equatable { case ok, refused, unavailable }
    public enum Cache: Sendable, Equatable { case unknown, missing, available }
    public enum Item: Sendable, Equatable { case none, present, unavailable }

    public let phase: Phase
    public let outcome: Outcome
    public let cache: Cache
    public let item: Item

    fileprivate init(phase: Phase, outcome: Outcome, cache: Cache, item: Item) {
        self.phase = phase
        self.outcome = outcome
        self.cache = cache
        self.item = item
    }
}
#endif

/// The Security boundary used by Secrets. Fixture tests inject this privately
/// so operation order and item identity can be checked without reading key data.
struct CredentialSecurity: Sendable {
    enum Read: Sendable { case found(String), missing, failed }
    #if DEBUG
    enum OwnedAdd: Sendable { case created(Data?), duplicate, failed }
    #endif

    let read: @Sendable (String, String) -> Read
    let presence: @Sendable (String, String) -> CredentialAvailability
    let write: @Sendable (String, String, String?) -> Bool
    #if DEBUG
    let addOwned: @Sendable (String, String, String, Data) -> OwnedAdd
    let ownedPresence: @Sendable (Data, Data) -> Bool
    let replaceOwned: @Sendable (Data, Data, String) -> Bool
    let removeOwned: @Sendable (Data, Data) -> Bool
    #endif

    #if !DEBUG
    init(
        read: @escaping @Sendable (String, String) -> Read,
        presence: @escaping @Sendable (String, String) -> CredentialAvailability,
        write: @escaping @Sendable (String, String, String?) -> Bool
    ) {
        self.read = read
        self.presence = presence
        self.write = write
    }
    #endif

    #if DEBUG
    init(
        read: @escaping @Sendable (String, String) -> Read,
        presence: @escaping @Sendable (String, String) -> CredentialAvailability,
        write: @escaping @Sendable (String, String, String?) -> Bool,
        addOwned: @escaping @Sendable (String, String, String, Data) -> OwnedAdd,
        ownedPresence: @escaping @Sendable (Data, Data) -> Bool,
        replaceOwned: @escaping @Sendable (Data, Data, String) -> Bool,
        removeOwned: @escaping @Sendable (Data, Data) -> Bool
    ) {
        self.read = read
        self.presence = presence
        self.write = write
        self.addOwned = addOwned
        self.ownedPresence = ownedPresence
        self.replaceOwned = replaceOwned
        self.removeOwned = removeOwned
    }
    #endif

    #if DEBUG
    static let live = CredentialSecurity(
        read: Keychain.read,
        presence: Keychain.presence,
        write: Keychain.write,
        addOwned: Keychain.addOwned,
        ownedPresence: Keychain.ownedPresence,
        replaceOwned: Keychain.replaceOwned,
        removeOwned: Keychain.removeOwned
    )
    #else
    static let live = CredentialSecurity(read: Keychain.read, presence: Keychain.presence, write: Keychain.write)
    #endif
}

/// API keys in the Keychain (#8): generic passwords, service = bundle id,
/// account = `CredentialID.account`. Lookup reads each key once and keeps the
/// result in memory. A failed read is not cached. Headless runs use environment
/// variables instead because their Keychain ACL belongs to the app.
/// Nothing here logs: a key never reaches a log, an error message or History.
public final class Secrets: Sendable {
    public enum Source: Sendable { case keychain(service: String), environment }

    private enum LookupDecision {
        case suppressed
        case cached(String?)
        case read(UInt64)
    }

    private enum ReadDecision {
        case suppressed
        case cached(String?)
        case retry
        case stored(String?)
    }

    private struct State {
        var cache: [CredentialID: String?] = [:]
        var revisions: [CredentialID: UInt64] = [:]
        #if DEBUG
        var fixture = FixtureState()
        #endif
    }

    #if DEBUG
    private struct FixtureState: Sendable {
        enum Phase: Sendable, Equatable { case idle, reserved, refused, owned(Data, Data), removed, stranded }
        var phase: Phase = .idle
    }
    #endif

    let source: Source
    private let security: CredentialSecurity
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "dev.jparker.lexicon.credentials")
    #if DEBUG
    private let fixtureTestServiceAllowed: Bool
    #endif

    public convenience init(_ source: Source) {
        #if DEBUG
        self.init(source, security: .live, fixtureTestServiceAllowed: false)
        #else
        self.init(source, security: .live)
        #endif
    }

    #if DEBUG
    convenience init(_ source: Source, security: CredentialSecurity) {
        self.init(source, security: security, fixtureTestServiceAllowed: false)
    }

    private init(_ source: Source, security: CredentialSecurity, fixtureTestServiceAllowed: Bool) {
        self.source = source
        self.security = security
        self.fixtureTestServiceAllowed = fixtureTestServiceAllowed
    }
    #else
    private init(_ source: Source, security: CredentialSecurity) {
        self.source = source
        self.security = security
    }
    #endif

    #if DEBUG
    static func fixtureForTesting(service: String, security: CredentialSecurity = .live) -> Secrets? {
        let prefix = "dev.jparker.lexicon.settings-fixture-tests."
        guard service.hasPrefix(prefix) else { return nil }
        let suffix = String(service.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: suffix), uuid.uuidString == suffix else { return nil }
        return Secrets(.keychain(service: service), security: security, fixtureTestServiceAllowed: true)
    }

    func settingsFixture(
        _ action: SettingsFixtureAction,
        completion: @escaping @Sendable (SettingsFixtureObservation) -> Void
    ) {
        queue.async { [self] in completion(runFixture(action)) }
    }
    #endif

    /// Handed to `CloudAccess.granted(by:for:keys:)`. Called only when a cloud
    /// call needs its key: the speech stream asks at fn-down, when it opens.
    public var lookup: @Sendable (CredentialID) -> String? {
        switch source {
        case .keychain(let service): { [self] id in lookupKeychain(id, service: service) }
        case .environment: { ProcessInfo.processInfo.environment[Secrets.environmentName(for: $0)] }
        }
    }

    /// The Settings owner-bound command. Every request is serialized off the
    /// opening thread and returns only a bounded result.
    public var credentials: CredentialCommand {
        { [self] edit, completion in
            queue.async { [self] in
                let result = apply(edit)
                // Deliver the bounded result in a later queue turn so the request
                // and its submitted key are released before client code runs.
                queue.async { completion(result) }
            }
        }
    }

    /// `LEXICON_KEY_` plus the Keychain account, upper case, `.` and `-` as `_`:
    /// `cleanup.openrouter` is `LEXICON_KEY_CLEANUP_OPENROUTER`.
    static func environmentName(for id: CredentialID) -> String {
        "LEXICON_KEY_" + String(id.account.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private func lookupKeychain(_ id: CredentialID, service: String) -> String? {
        while true {
            let decision = state.withLock { state -> LookupDecision in
                #if DEBUG
                if id == .jev, fixtureSuppressesLookup(state.fixture.phase) { return .suppressed }
                #endif
                if let cached = state.cache[id] { return .cached(cached) }
                return .read(state.revisions[id, default: 0])
            }
            switch decision {
            case .suppressed: return nil
            case .cached(let value): return value
            case .read(let revision):
                let value: String?
                switch security.read(service, id.account) {
                case .found(let key):
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    value = trimmed.isEmpty ? nil : trimmed
                case .missing: value = nil
                case .failed: return nil
                }
                let result = state.withLock { state -> ReadDecision in
                    #if DEBUG
                    if id == .jev, fixtureSuppressesLookup(state.fixture.phase) { return .suppressed }
                    #endif
                    if let newer = state.cache[id] { return .cached(newer) }
                    guard state.revisions[id, default: 0] == revision else { return .retry }
                    state.cache[id] = value
                    return .stored(value)
                }
                switch result {
                case .suppressed: return nil
                case .cached(let newer): return newer
                case .retry: continue
                case .stored(let stored): return stored
                }
            }
        }
    }

    private func apply(_ edit: CredentialEdit) -> CredentialOutcome {
        guard case .keychain(let service) = source else {
            if case .availability = edit { return .availability(.unavailable) }
            return .unavailable
        }
        switch edit {
        case .availability(let id):
            #if DEBUG
            if id == .jev, fixtureIsActive { return .availability(.unavailable) }
            #endif
            return .availability(security.presence(service, id.account))
        case .save(let id, let submitted):
            let value = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return .emptyEntry }
            #if DEBUG
            if id == .jev, fixtureIsActive { return saveFixture(value, service: service) }
            #endif
            guard security.write(service, id.account, value) else { return .unavailable }
            state.withLock { state in
                state.cache[id] = value
                advanceRevision(id, state: &state)
            }
            return .saved
        case .remove(let id):
            #if DEBUG
            if id == .jev, fixtureIsActive { return removeFixture(id) }
            #endif
            guard security.write(service, id.account, nil) else { return .unavailable }
            state.withLock { state in
                state.cache[id] = .some(nil)
                advanceRevision(id, state: &state)
            }
            return .removed
        }
    }

    #if DEBUG
    private var fixtureIsActive: Bool {
        state.withLock { fixtureSuppressesLookup($0.fixture.phase) }
    }

    private func fixtureSuppressesLookup(_ phase: FixtureState.Phase) -> Bool {
        if case .idle = phase { return false }
        return true
    }

    private func canRunFixture() -> Bool {
        if fixtureTestServiceAllowed { return true }
        guard case .keychain(let service) = source else { return false }
        return service == AppPaths.devBundleID
    }

    private func runFixture(_ action: SettingsFixtureAction) -> SettingsFixtureObservation {
        guard canRunFixture() else {
            return observation(phase: .idle, outcome: .refused)
        }
        switch action {
        case .begin:
            let phase = state.withLock { state -> FixtureState.Phase in
                advanceRevision(.jev, state: &state)
                if case .idle = state.fixture.phase { state.fixture.phase = .reserved }
                return state.fixture.phase
            }
            return observation(phase: phase, outcome: phase == .stranded ? .unavailable : .ok)
        case .inspect:
            let phase = state.withLock { $0.fixture.phase }
            return observation(phase: phase, outcome: phase == .stranded ? .unavailable : .ok)
        case .end:
            let phase = state.withLock { state -> FixtureState.Phase in
                advanceRevision(.jev, state: &state)
                return state.fixture.phase
            }
            switch phase {
            case .idle:
                return observation(phase: .idle, outcome: .ok)
            case .reserved, .refused, .removed:
                state.withLock { $0.fixture.phase = .idle }
                return observation(phase: .idle, outcome: .ok)
            case .stranded:
                return observation(phase: .stranded, outcome: .unavailable)
            case .owned(let reference, let marker):
                guard security.ownedPresence(reference, marker) else {
                    return observation(phase: .owned(reference, marker), outcome: .unavailable, item: .unavailable)
                }
                guard security.removeOwned(reference, marker) else {
                    return observation(phase: .owned(reference, marker), outcome: .unavailable, item: .unavailable)
                }
                state.withLock { state in
                    state.fixture.phase = .idle
                    state.cache[.jev] = .some(nil)
                    advanceRevision(.jev, state: &state)
                }
                return observation(phase: .idle, outcome: .ok)
            }
        }
    }

    private func saveFixture(_ value: String, service: String) -> CredentialOutcome {
        let phase = state.withLock { $0.fixture.phase }
        switch phase {
        case .reserved:
            let marker = Data(UUID().uuidString.utf8)
            switch security.addOwned(service, CredentialID.jev.account, value, marker) {
            case .duplicate:
                state.withLock { $0.fixture.phase = .refused }
                return .refused
            case .failed:
                return .unavailable
            case .created(let reference):
                guard let reference, !reference.isEmpty else {
                    state.withLock { $0.fixture.phase = .stranded }
                    return .unavailable
                }
                state.withLock { state in
                    state.fixture.phase = .owned(reference, marker)
                    state.cache[.jev] = value
                    advanceRevision(.jev, state: &state)
                }
                return .saved
            }
        case .owned(let reference, let marker):
            guard security.ownedPresence(reference, marker) else { return .unavailable }
            guard security.replaceOwned(reference, marker, value) else { return .unavailable }
            state.withLock { state in
                state.cache[.jev] = value
                advanceRevision(.jev, state: &state)
            }
            return .saved
        case .refused: return .refused
        case .stranded: return .unavailable
        case .removed: return .refused
        case .idle:
            return .unavailable
        }
    }

    private func removeFixture(_ id: CredentialID) -> CredentialOutcome {
        let phase = state.withLock { $0.fixture.phase }
        switch phase {
        case .owned(let reference, let marker):
            guard security.ownedPresence(reference, marker) else { return .unavailable }
            guard security.removeOwned(reference, marker) else { return .unavailable }
            state.withLock { state in
                state.fixture.phase = .removed
                state.cache[id] = .some(nil)
                advanceRevision(id, state: &state)
            }
            return .removed
        case .removed: return .removed
        case .stranded: return .unavailable
        case .refused: return .refused
        case .reserved, .idle: return .unavailable
        }
    }

    private func observation(
        phase: FixtureState.Phase,
        outcome: SettingsFixtureObservation.Outcome,
        item requestedItem: SettingsFixtureObservation.Item? = nil
    ) -> SettingsFixtureObservation {
        let cache = state.withLock { state -> SettingsFixtureObservation.Cache in
            guard let cached = state.cache[.jev] else { return .unknown }
            return cached == nil ? .missing : .available
        }
        let publicPhase: SettingsFixtureObservation.Phase
        let item: SettingsFixtureObservation.Item
        switch phase {
        case .idle: publicPhase = .idle; item = .none
        case .reserved: publicPhase = .reserved; item = .none
        case .refused: publicPhase = .refused; item = .none
        case .owned(let reference, let marker):
            publicPhase = .owned
            item = requestedItem ?? (security.ownedPresence(reference, marker) ? .present : .unavailable)
        case .removed: publicPhase = .removed; item = .none
        case .stranded: publicPhase = .stranded; item = .none
        }
        let boundedOutcome = item == .unavailable && outcome == .ok ? .unavailable : outcome
        return SettingsFixtureObservation(phase: publicPhase, outcome: boundedOutcome, cache: cache, item: item)
    }
    #endif

    private func advanceRevision(_ id: CredentialID, state: inout State) {
        state.revisions[id, default: 0] &+= 1
    }
}

/// Login Keychain generic passwords. The only Security importer (scripts/check-imports.swift).
private enum Keychain {
    static func read(service: String, account: String) -> CredentialSecurity.Read {
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

    static func presence(service: String, account: String) -> CredentialAvailability {
        var query = item(service: service, account: account)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return .saved
        case errSecItemNotFound: return .missing
        default: return .unavailable
        }
    }

    /// Keeps existing Keychain permissions by updating an item in place.
    static func write(service: String, account: String, value: String?) -> Bool {
        let query = item(service: service, account: account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func item(service: String, account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    #if DEBUG
    /// The fixture's first write is add-only and returns the only cleanup handle.
    static func addOwned(service: String, account: String, value: String, marker: Data) -> CredentialSecurity.OwnedAdd {
        var query = item(service: service, account: account)
        query[kSecValueData] = Data(value.utf8)
        query[kSecAttrGeneric] = marker
        query[kSecReturnPersistentRef] = true
        var result: CFTypeRef?
        switch SecItemAdd(query as CFDictionary, &result) {
        case errSecSuccess: return .created(result as? Data)
        case errSecDuplicateItem: return .duplicate
        default: return .failed
        }
    }

    static func ownedPresence(reference: Data, marker: Data) -> Bool {
        var query = referenceItem(reference)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let attributes = result as? [CFString: Any]
        let observedMarker = attributes?[kSecAttrGeneric] as? Data
        guard status == errSecSuccess, let storedMarker = observedMarker else { return false }
        return storedMarker == marker
    }

    static func replaceOwned(reference: Data, marker: Data, value: String) -> Bool {
        let query = referenceItem(reference, marker: marker)
        return SecItemUpdate(query as CFDictionary, [kSecValueData: Data(value.utf8)] as CFDictionary) == errSecSuccess
    }

    static func removeOwned(reference: Data, marker: Data) -> Bool {
        let status = SecItemDelete(referenceItem(reference, marker: marker) as CFDictionary)
        return status == errSecSuccess
    }

    private static func referenceItem(_ reference: Data, marker: Data? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecValuePersistentRef: reference]
        if let marker { query[kSecAttrGeneric] = marker }
        return query
    }
    #endif
}
