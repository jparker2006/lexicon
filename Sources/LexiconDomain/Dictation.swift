public import Foundation

// Value types for one Dictation, nothing else. A type lives here only when
// two or more modules need it; anything one module needs stays in that module.

/// Identity of one Dictation. Also names its audio file (`audio/<id>.caf`).
public struct DictationID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID
    public init() { self.uuid = UUID() }
    public init(uuid: UUID) { self.uuid = uuid }
    public var description: String { uuid.uuidString }
}

/// Where the audio came from. Decides whether text may ever be typed.
public enum DictationOrigin: String, Sendable, Codable, CaseIterable {
    /// Jake pressed fn. The only origin that can type.
    case live
    /// Found on launch after a crash. Transcribed, never typed (#4).
    case recovered
    /// Test hook or `lexicon-eval`: audio from a file.
    case file
}

/// What the text is for. A Re-speak fix is a Dictation too: its audio is saved,
/// but its text replaces a word in an earlier Dictation instead of being inserted.
public enum DictationPurpose: Sendable, Hashable, Codable {
    case type
    case respeak(of: DictationID)
}

/// Gesture that produced a live Dictation (#6). Starting values tuned in #18.
public enum DictationMode: String, Sendable, Codable, CaseIterable {
    case hold
    case handsFree
}

/// The status shown in History (grey text). The ONE list of statuses: History
/// persists `rawValue`, the UI label is an exhaustive switch, so adding a case
/// fails the build until every reader handles it. No SQL CHECK list to sync.
public enum DictationStatus: String, Sendable, Codable, CaseIterable {
    case recording
    case transcribing
    /// No model could answer (cloud down, no local model yet). Retries when the network returns.
    case waiting
    /// Text saved (`.textReady` queued) and the paste is in progress. Lasts
    /// milliseconds. Launch recovery turns a leftover `ready` into `notInserted`
    /// (reason `interrupted`) and never types it again.
    case ready
    case inserted
    /// Text is ready but focus moved or Jake typed since stop. Paste-last inserts it.
    case notInserted
    /// Found after a crash; text ready; never typed.
    case recovered
    /// No text could be produced (audio missing, silent input).
    case failed

    /// Still owned by a running Conductor task; History refuses delete while true.
    public var isInFlight: Bool {
        switch self {
        case .recording, .transcribing, .ready: true
        case .waiting, .inserted, .notInserted, .recovered, .failed: false
        }
    }

    public var hasText: Bool {
        switch self {
        case .ready, .inserted, .notInserted, .recovered: true
        case .recording, .transcribing, .waiting, .failed: false
        }
    }

    /// Settled: no running task will move it again. Only a user action (paste-last,
    /// Retry) can. Everything not terminal is what launch recovery scans, so History
    /// GENERATES its partial index from this property (no hand-listed statuses).
    public var isTerminal: Bool {
        switch self {
        case .inserted, .notInserted, .recovered, .failed: true
        case .recording, .transcribing, .waiting, .ready: false
        }
    }

    /// Audio must be kept: the Dictation still waits for text, or failed and waits
    /// for a manual Retry (#4). Retention's skip-list is generated from this.
    public var needsAudio: Bool {
        switch self {
        case .recording, .transcribing, .waiting, .failed: true
        case .ready, .inserted, .notInserted, .recovered: false
        }
    }

    /// The transition table. History's `apply` moves a row only when this allows it
    /// from the STORED status, so a replayed or racing event is a no-op by
    /// construction. Same-state moves are allowed and change nothing (replays).
    public func canMove(to next: DictationStatus) -> Bool {
        if self == next { return true }
        switch self {
        case .recording:
            // notInserted and recovered: launch recovery's moves (a crash mid-recording).
            return [.transcribing, .waiting, .failed, .notInserted, .recovered].contains(next)
        case .transcribing: return [.ready, .waiting, .failed, .notInserted, .recovered].contains(next)
        case .waiting: return [.ready, .failed, .notInserted, .recovered].contains(next)  // late text (#4)
        case .ready: return [.inserted, .notInserted].contains(next)  // the paste's real outcome
        case .notInserted, .recovered: return next == .inserted  // paste-last
        case .failed: return [.notInserted, .recovered].contains(next)  // manual Retry produced text
        case .inserted: return false
        }
    }
}

/// The text a Dictation produced, as Lexicon made it (#4 keeps three versions).
///
/// The third version, final text (after Fixes), is deliberately NOT here: only
/// History materializes it, from `cleaned` plus the recorded Fixes, in the same
/// transaction as the Fix row. Read it from `DictationRecord.finalText`.
/// Nothing outside History can set it, because no type outside History holds it.
public struct TextVersions: Sendable, Hashable, Codable {
    /// What the speech model returned.
    public let model: String
    /// After Cleanup (AI cleanup accepted, or the rules-only fallback): what Lexicon inserted.
    public let cleaned: String
    public init(model: String, cleaned: String) {
        self.model = model
        self.cleaned = cleaned
    }
}

/// Why text that is ready was not typed.
public enum NotInsertedReason: String, Sendable, Codable, CaseIterable {
    case focusMoved
    case typedSince
    case noField
    /// The app exposed no focused field, so only "same app" could be checked,
    /// and the paste came 5 s or more after fn-up, or after the ⌃⌘V press
    /// (`InsertGuard.fieldlessWindow`).
    case tooLate
    case pasteFailed
    /// Jake set "Paste from Other Apps" to deny Lexicon: it can't save his
    /// clipboard, so it never replaces it.
    case clipboardDenied
    /// Lexicon stopped mid-paste (crash, quit). The text may or may not have landed,
    /// so it is never typed again; paste-last still reaches it.
    case interrupted
}

/// Where a Dictation's text landed, kept durably (History's `insertion` table) so
/// Re-speak and Hand fix can find the text again after the live Accessibility
/// references (memory only, inside AppText) are gone: app quit, restart, a day later.
/// A record, not a capability: holding one lets nobody type anything.
public struct InsertionReceipt: Sendable, Hashable, Codable {
    public let appBundleID: String?
    /// Opaque to everyone but AppText: identifies the field across restarts
    /// (bundle id + AX role path + identifier, hashed). nil when the app exposes nothing.
    public let fieldFingerprint: String?
    /// Caret offset (UTF-16) right after the paste, when the field exposes one.
    public let caretAfter: Int?
    /// About 40 characters each side of the inserted text, read once after the
    /// paste. Never read from secure fields.
    public let contextBefore: String
    public let contextAfter: String
    public let insertedAt: Date
    public init(appBundleID: String?, fieldFingerprint: String?, caretAfter: Int?,
                contextBefore: String, contextAfter: String, insertedAt: Date) {
        self.appBundleID = appBundleID
        self.fieldFingerprint = fieldFingerprint
        self.caretAfter = caretAfter
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.insertedAt = insertedAt
    }
}

/// What happened to the text at the end of a Dictation.
public enum Delivery: Sendable, Hashable, Codable {
    case inserted(InsertionReceipt)
    case notInserted(NotInsertedReason)
    /// Never meant to be typed: recovered, manual retry, Re-speak audio.
    case historyOnly
}

/// What a Dictation's audio left behind.
public struct AudioSummary: Sendable, Hashable, Codable {
    public var duration: Duration
    /// fn-down to first sample. Logged on every row so clipping is a number (#4).
    public var startGap: Duration?
    public var deviceName: String?
    public var storage: AudioStorage
    /// Device changes mid-Dictation: gap lengths, same file kept.
    public var gaps: [Duration]
    public init(duration: Duration, startGap: Duration?, deviceName: String?, storage: AudioStorage, gaps: [Duration]) {
        self.duration = duration
        self.startGap = startGap
        self.deviceName = deviceName
        self.storage = storage
        self.gaps = gaps
    }
}

public enum AudioStorage: String, Sendable, Codable, CaseIterable {
    case onDisk
    /// Disk nearly full or a write failed: audio lives only in RAM until text lands (#4).
    case ramOnly
    /// Removed by Delete; the row goes too.
    case deleted
    /// Removed by retention; the row keeps its text, but play and Retry have nothing to use.
    case expired
}

/// A prompt Claude Code or Codex reports through its UserPromptSubmit hook (#13).
public struct SubmittedPrompt: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Codable { case claudeCode, codex }
    public var source: Source
    public var text: String
    public var workingDirectory: String?
    public var submittedAt: Date
    public init(source: Source, text: String, workingDirectory: String?, submittedAt: Date) {
        self.source = source
        self.text = text
        self.workingDirectory = workingDirectory
        self.submittedAt = submittedAt
    }
}

extension DictationStatus {
    /// The status `.textReady` moves a row to. A Dictation about to be typed goes to
    /// `.ready` (text saved, paste in progress) and only the paste's real outcome
    /// (`.delivered` or `.notInserted`) moves it on. Text never meant to be typed
    /// lands straight away through `landed(.historyOnly, ...)`.
    public static func afterTextReady(typing: Bool, origin: DictationOrigin, previous: DictationStatus?) -> DictationStatus {
        typing ? .ready : landed(.historyOnly, origin: origin, previous: previous)
    }

    /// The one rule for the status a Dictation lands in. History applies it to the
    /// row and the Conductor to its report, so they cannot disagree.
    public static func landed(_ delivery: Delivery, origin: DictationOrigin, previous: DictationStatus?) -> DictationStatus {
        switch delivery {
        case .inserted: return .inserted
        case .notInserted: return .notInserted
        case .historyOnly:
            // A row that already has text keeps its status (a Retry): a recovered
            // Dictation Jake pasted stays inserted.
            if let previous, previous.hasText { return previous }
            if origin == .recovered { return .recovered }
            return .notInserted
        }
    }
}
