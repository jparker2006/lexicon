import ServiceManagement

/// Start at login: `SMAppService.mainApp`, the app itself as the login item
/// (no helper). macOS owns the truth and the menu shows it. Lexicon registers
/// itself once, on first run (`Preferences.startAtLoginOffered`); after that a
/// login item Jake removed in System Settings > General > Login Items (macOS 26
/// reports `notRegistered`) or switched off there (`requiresApproval`) stays
/// that way, and only Lexicon's menu turns it back on.
@MainActor
enum LoginItem {
    enum Status: Sendable, Hashable {
        case enabled
        /// Registered, but Jake turned it off in System Settings (or hasn't approved it yet).
        case requiresApproval
        case notRegistered
    }

    enum Action: Sendable, Hashable {
        case register
        case unregister
        /// Only Jake can turn it back on once he turned it off in System Settings.
        case openSystemSettings
    }

    /// At launch: register when Jake wants it and Lexicon never offered it
    /// before; unregister when he turned it off in Lexicon's menu. Anything else
    /// is Jake's call in System Settings, left alone.
    nonisolated static func launchAction(wanted: Bool, offered: Bool, status: Status) -> Action? {
        switch (wanted, status) {
        case (true, .notRegistered): offered ? nil : .register
        case (false, .enabled), (false, .requiresApproval): .unregister
        default: nil
        }
    }

    /// The menu toggle. Turned off in System Settings, it can only be turned on there.
    nonisolated static func toggleAction(status: Status) -> Action {
        switch status {
        case .notRegistered: .register
        case .enabled: .unregister
        case .requiresApproval: .openSystemSettings
        }
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        // `.notFound` means macOS has no record of it, the same as never registered.
        case .notRegistered, .notFound: .notRegistered
        @unknown default: .notRegistered
        }
    }

    /// Errors only reach the log: the menu line shows the status that resulted.
    static func perform(_ action: Action) throws {
        switch action {
        case .register: try SMAppService.mainApp.register()
        case .unregister: try SMAppService.mainApp.unregister()
        case .openSystemSettings: SMAppService.openSystemSettingsLoginItems()
        }
    }
}
