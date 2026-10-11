/// First-run setup's steps, in order. Only Microphone and Accessibility are
/// permissions; the model and the fn try are what make the first Dictation work.
public enum SetupStep: Int, Sendable, Hashable, CaseIterable, Comparable {
    case microphone
    case accessibility
    case model
    case tryFn

    public static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }
}

public enum MicrophoneAccess: Sendable, Hashable {
    case undetermined
    case granted
    case denied
}

/// The local speech model, as the setup window shows it.
public enum ModelState: Sendable, Hashable {
    case missing
    /// 0...1 of the download.
    case downloading(Double)
    case installed
    /// Private mode is on, so nothing may be downloaded (#5).
    case privateMode
    /// The download stopped (network, disk). Retry starts it again.
    case failed
}

/// Everything setup reads from the system, as one value, so its rules are
/// tested without a window, a permission or a network.
public struct SetupFacts: Sendable, Hashable {
    public var microphone: MicrophoneAccess
    public var accessibility: Bool
    /// The fn tap is running. It starts only at launch, so a grant made while
    /// the app runs leaves it off until the relaunch.
    public var fnOn: Bool
    public var model: ModelState
    /// The globe key is set to Do Nothing. Shown in setup, never a step: Lexicon
    /// only reads the setting.
    public var globeKeyOK: Bool
    /// Some text landed in the setup window's try field.
    public var triedFn: Bool

    public init(microphone: MicrophoneAccess, accessibility: Bool, fnOn: Bool, model: ModelState,
                globeKeyOK: Bool, triedFn: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.fnOn = fnOn
        self.model = model
        self.globeKeyOK = globeKeyOK
        self.triedFn = triedFn
    }

    public func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .microphone: microphone == .granted
        case .accessibility: accessibility && fnOn
        case .model: model == .installed
        case .tryFn: triedFn
        }
    }

    /// The step the window points at: the first one not done, or nil when all are.
    public var current: SetupStep? { SetupStep.allCases.first { !isDone($0) } }

    /// The permission step the menu bar icon's warning dot opens, or nil for no
    /// dot. Only a missing or revoked permission (or fn off) shows it: a missing
    /// model is setup's job, not a warning.
    public var warning: SetupStep? {
        [SetupStep.microphone, .accessibility].first { !isDone($0) }
    }

    /// Whether the window opens by itself at launch. First run, or the relaunch
    /// after the Accessibility grant (setup carries on where it was). A permission
    /// revoked later only shows the dot: no popups.
    ///
    /// A Microphone answer is never undetermined again after the first run, so
    /// "undetermined" marks a first run without a saved flag (and a `tccutil
    /// reset` brings setup back, as it should).
    public func opensAtLaunch(relaunched: Bool) -> Bool {
        relaunched || microphone == .undetermined || model != .installed
    }
}

/// Granting Accessibility can't turn on the fn tap in a running process: the
/// tap starts only at launch. So setup relaunches the app the moment trust
/// appears, once per launch that began without it. A launch that began trusted
/// never relaunches, so a tap that still fails can't loop.
public struct RelaunchRule: Sendable, Hashable {
    public let trustedAtLaunch: Bool
    public init(trustedAtLaunch: Bool) { self.trustedAtLaunch = trustedAtLaunch }

    public func shouldRelaunch(trustedNow: Bool) -> Bool { !trustedAtLaunch && trustedNow }
}

/// How a row reads: done (a check), the one to do now (its button works), or
/// waiting for an earlier step (greyed).
public enum RowState: Sendable, Hashable {
    case done
    case current
    case waiting
}

/// One row of the setup window: what it says and its one button, if any.
public struct SetupRow: Sendable, Hashable {
    public var title: String
    public var detail: String
    public var button: String?
    public var state: RowState
    /// 0...1 while the model downloads; the row shows a bar.
    public var progress: Double?
}

/// The setup window's words, decided here so the rules and the copy are tested
/// together. No em dashes (Jake reads these).
public enum SetupCopy {
    public static let modelSize = "about 610 MB"

    public static func row(_ step: SetupStep, _ facts: SetupFacts) -> SetupRow {
        let state: RowState = facts.isDone(step) ? .done : facts.current == step ? .current : .waiting
        func row(_ title: String, _ detail: String, _ button: String? = nil, progress: Double? = nil) -> SetupRow {
            SetupRow(title: title, detail: detail, button: state == .done ? nil : button, state: state, progress: progress)
        }
        switch step {
        case .microphone:
            return switch facts.microphone {
            case .granted: row("Microphone", "Allowed.")
            case .undetermined: row("Microphone", "Lexicon listens only while you hold fn.", "Allow Microphone")
            case .denied: row("Microphone", "Turned off for Lexicon. Turn it on in System Settings.", "Open System Settings")
            }
        case .accessibility:
            if !facts.accessibility {
                return row("Accessibility", "Lexicon needs it to hear fn and paste where you type. Turn on Lexicon in the list, and it restarts by itself.",
                           "Open System Settings")
            }
            return facts.fnOn
                ? row("Accessibility", "Allowed. fn is on.")
                : row("Accessibility", "Allowed. Restart Lexicon to turn on fn.", "Restart Lexicon")
        case .model:
            return switch facts.model {
            case .installed: row("Speech model", "Installed. Your words are transcribed on this Mac.")
            case .missing: row("Speech model", "Transcribes on this Mac. A one-time download, \(modelSize).", "Download")
            case .downloading(let fraction):
                row("Speech model", "Downloading, \(Int((fraction * 100).rounded(.down)))%.", progress: fraction)
            case .privateMode: row("Speech model", "Private mode is on, so nothing downloads. Turn it off, then try again.", "Try Again")
            case .failed: row("Speech model", "The download stopped. Check your connection, then try again.", "Try Again")
            }
        case .tryFn:
            return facts.triedFn
                ? row("Try it", "It works. Hold fn anywhere you type.")
                : row("Try it", "Click in the box, hold fn and say something. Let go, and your words appear.")
        }
    }

    /// The globe key line under the steps. Lexicon only reads the setting.
    public static func globeKey(ok: Bool) -> (detail: String, button: String?) {
        ok ? ("Globe key: set to Do Nothing.", nil)
            : ("Set “Press globe key to” to Do Nothing, or macOS also acts on every fn press.", "Open Keyboard Settings")
    }

    /// The menu bar menu's line for the step the warning dot points at.
    public static func warningMenuTitle(_ step: SetupStep) -> String {
        switch step {
        case .microphone: "Microphone is off: Set Up…"
        case .accessibility: "fn is off: Set Up…"
        case .model, .tryFn: "Set Up Lexicon…"
        }
    }

    /// The menu bar icon's accessibility label while the dot shows, so the
    /// harness (and VoiceOver) can read the dot.
    public static func warningLabel(_ step: SetupStep) -> String {
        switch step {
        case .microphone: "Microphone is off"
        case .accessibility: "fn is off"
        case .model, .tryFn: "setup not finished"
        }
    }
}
