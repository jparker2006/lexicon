import Foundation
import Synchronization

public enum PrivacyMode: String, Sendable, Codable, CaseIterable {
    case standard
    /// Nothing leaves the Mac (#5): no network at all from Lexicon, model
    /// downloads and status checks included. Survives quit and reboot.
    case `private`
}

/// Every user setting, as one value. Owned by `PreferencesStore` (LexiconCore),
/// which is the only code that touches UserDefaults. The Conductor snapshots it
/// once per Dictation and passes the values down, so a setting changed while
/// Jake talks never changes the Dictation in flight (same rule as the pinned mic).
public struct Preferences: Sendable, Hashable, Codable {
    public var privacy: PrivacyMode
    /// Bundle IDs that are always private (#5). Starts empty; Jake adds apps.
    public var alwaysPrivateApps: Set<String>
    /// nil: no cloud engine, local Parakeet only. M0 and M1 run local only; the
    /// Muse adapter lands in M2 (#67), which makes `.museVoice` the default.
    public var cloudModel: CloudModel?
    public var localModel: LocalModel?
    /// Core Audio device UID. nil means the built-in mic (#4). Also settable with
    /// `--args -microphone <uid>`.
    public var microphoneUID: String?
    /// The cloud wins if its final text arrives within this long after recording
    /// stops; otherwise local text is used. Fixed in code, not shown in Settings.
    public var raceDeadline: Duration
    /// Keep the local model resident this long after the last Dictation. Ignored
    /// (always resident) while Private mode is on or the network is unreachable:
    /// the rule lives in `Transcription/RacePolicy.swift` `ResidencyPolicy`.
    public var localModelLinger: Duration
    /// The "AI cleanup" toggle (#20), on by default. Off = rules-only cleanup and
    /// nothing leaves the Mac for cleanup (Cleanup withholds `CloudAccess`).
    /// Inert until M3 (#75): M0 to M2 run rules-only Cleanup.
    public var aiCleanup: Bool
    public var cleanupModel: CloudCleanupModel
    /// How long a live Dictation's cleanup may wait for the LLM after the speech
    /// final arrives, before the rules-only text is typed. A starting value,
    /// tuned on the Test set to keep total lag within the pass mark.
    public var cleanupDeadline: Duration
    /// Most relevant Lexicon Terms, best first, chosen at fn-down: speech gets
    /// the first `speechTerms` (fewer if a provider cap binds), Cleanup gets the
    /// first `cleanupTerms`. Private mode sends no list.
    public var speechTerms: Int
    public var cleanupTerms: Int
    /// Jake's choice in Lexicon's menu. On by default (#57).
    public var startAtLogin: Bool
    /// Lexicon has registered itself at login once. After that only Jake adds
    /// or removes the login item: one he removed in System Settings stays removed.
    public var startAtLoginOffered: Bool
    /// The "Sounds on" toggle (#55): the start, stop, warning and error blips. On by default.
    public var soundsOn: Bool

    public init(privacy: PrivacyMode, alwaysPrivateApps: Set<String>, cloudModel: CloudModel?, localModel: LocalModel?, microphoneUID: String?,
                raceDeadline: Duration, localModelLinger: Duration, aiCleanup: Bool,
                cleanupModel: CloudCleanupModel, cleanupDeadline: Duration, speechTerms: Int, cleanupTerms: Int,
                startAtLogin: Bool, startAtLoginOffered: Bool, soundsOn: Bool) {
        self.privacy = privacy
        self.alwaysPrivateApps = alwaysPrivateApps
        self.cloudModel = cloudModel
        self.localModel = localModel
        self.microphoneUID = microphoneUID
        self.raceDeadline = raceDeadline
        self.localModelLinger = localModelLinger
        self.aiCleanup = aiCleanup
        self.cleanupModel = cleanupModel
        self.cleanupDeadline = cleanupDeadline
        self.speechTerms = speechTerms
        self.cleanupTerms = cleanupTerms
        self.startAtLogin = startAtLogin
        self.startAtLoginOffered = startAtLoginOffered
        self.soundsOn = soundsOn
    }

    public static let defaults = Preferences(
        privacy: .standard, alwaysPrivateApps: [], cloudModel: nil, localModel: .parakeetUnified, microphoneUID: nil,
        raceDeadline: .milliseconds(300), localModelLinger: .seconds(600), aiCleanup: true,
        cleanupModel: .openRouterFast, cleanupDeadline: .milliseconds(450), speechTerms: 50, cleanupTerms: 200,
        startAtLogin: true, startAtLoginOffered: false, soundsOn: true
    )
}

/// Which secret a cloud call needs. Derived from `CloudModel`, never hand-listed.
public enum CredentialID: Hashable, Sendable {
    case speech(CloudModel)
    case jev
    /// OpenRouter, for AI cleanup (one key for every `CloudCleanupModel`).
    case cleanup
    /// Keychain account name (service = bundle id).
    public var account: String {
        switch self {
        case .speech(let m): "speech." + m.rawValue
        case .jev: "jev"
        case .cleanup: "cleanup.openrouter"
        }
    }
}

/// Why network access ended in the middle of a Dictation (#5).
public enum AccessRevoked: String, Sendable, Codable, CaseIterable {
    /// Jake turned Private mode on.
    case privateModeOn
    /// Focus moved into an always-private app.
    case alwaysPrivateApp
    /// The Secret guard matched text from this Dictation.
    case secretFound
}

/// Permission to use the network, plus the keys to do it. The ONLY door to the
/// network: speech, Cleanup's LLM, Jev and model downloads all take one.
///
/// Private mode is encoded as the ABSENCE of this value: the only constructor
/// returns nil in Private mode or for an always-private app. A new cloud feature
/// cannot forget to check Private mode, because it cannot be called without this.
/// One value per Dictation, revocable mid-Dictation (#5): once revoked, every key
/// lookup returns nil, speech sessions cut their stream, and the local model,
/// already racing, finishes the text.
public final class CloudAccess: Sendable {
    private struct State {
        var revoked: AccessRevoked?
        var waiters: [Int: CheckedContinuation<AccessRevoked?, Never>] = [:]
        var nextWaiter = 0
    }

    private let lookup: @Sendable (CredentialID) -> String?
    private let state = Mutex(State())
    private init(lookup: @escaping @Sendable (CredentialID) -> String?) { self.lookup = lookup }

    /// The only constructor. Called by the Conductor once per Dictation (after the
    /// active app is known) and by model install with `app: .unknown`.
    public static func granted(by preferences: Preferences, app: AppContext,
                               keys: @escaping @Sendable (CredentialID) -> String?) -> CloudAccess? {
        guard preferences.privacy == .standard else { return nil }
        if let id = app.bundleID, preferences.alwaysPrivateApps.contains(id) { return nil }
        return CloudAccess(lookup: keys)
    }

    /// Key for a call that carries no Dictation text: the speech audio stream, a
    /// model download. nil once revoked, including by a revoke that lands while
    /// the first Keychain read waits on its prompt.
    public func key(_ id: CredentialID) -> String? {
        guard revoked == nil, let key = lookup(id), revoked == nil else { return nil }
        return key
    }

    /// Key for a call that sends `text` (Cleanup's LLM, Jev). Runs the Secret guard
    /// first: a match revokes this access for the rest of the Dictation and
    /// returns nil, so the text never leaves.
    public func key(_ id: CredentialID, sending text: String) -> String? {
        guard revoked == nil else { return nil }
        if SecretGuard.matches(text) {
            revoke(.secretFound)
            return nil
        }
        return key(id)
    }

    /// Ends network use for the rest of this Dictation. Idempotent: the first reason wins.
    public func revoke(_ reason: AccessRevoked) {
        let waiters = state.withLock { state -> [CheckedContinuation<AccessRevoked?, Never>] in
            guard state.revoked == nil else { return [] }
            state.revoked = reason
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: reason) }
    }

    public var revoked: AccessRevoked? { state.withLock { $0.revoked } }

    /// Resumes when access is revoked, at once if it already is. A speech session
    /// races this against its socket and closes the stream the instant it fires.
    /// nil when the waiting task is cancelled first (the socket ended), so a
    /// task group racing the two can always finish.
    public func whenRevoked() async -> AccessRevoked? {
        let id = state.withLock { state in
            state.nextWaiter += 1
            return state.nextWaiter
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                // Under the lock, so a cancel either sees this waiter or was already
                // visible to `Task.isCancelled` (it is set before `onCancel` runs).
                let now: AccessRevoked?? = state.withLock { state in
                    if let reason = state.revoked { return .some(reason) }
                    if Task.isCancelled { return .some(nil) }
                    state.waiters[id] = waiter
                    return .none
                }
                if let now { waiter.resume(returning: now) }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: nil)
        }
    }
}
