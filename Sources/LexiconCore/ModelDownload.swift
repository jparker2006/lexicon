public import LexiconDomain

extension PreferencesStore {
    /// Network access for one model download (first-run setup), under the same
    /// rule as every cloud use (`cloudDenied(for: .modelInstall)`): Private mode
    /// blocks downloads too (#5). While it denies, this throws
    /// `CloudAccessRevoked` before `work` starts; turning Private mode on
    /// mid-download revokes the access, which ends a download that runs under
    /// `CloudAccess.untilRevoked`.
    public func downloading<T: Sendable>(_ work: @Sendable (CloudAccess) async throws -> T) async throws -> T {
        // Subscribed before the grant, so a switch made in between is not missed.
        let changes = changes()
        let settings = snapshot()
        let access = CloudAccess.granted(by: settings, for: .modelInstall, keys: { _ in nil })
        // Iterated even when access was refused: cancelling the iteration is what
        // ends the subscription in the store.
        let watch = Task {
            for await preferences in changes {
                guard let reason = preferences.cloudDenied(for: .modelInstall) else { continue }
                access?.revoke(reason)
                return
            }
        }
        defer { watch.cancel() }
        guard let access else { throw CloudAccessRevoked(settings.cloudDenied(for: .modelInstall) ?? .privateModeOn) }
        return try await work(access)
    }
}
