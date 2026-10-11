public import LexiconDomain

extension PreferencesStore {
    /// Network access for one model download (first-run setup). Private mode
    /// blocks downloads too (#5): while it is on this throws
    /// `CloudAccessRevoked(.privateModeOn)` before `work` starts, and turning it
    /// on mid-download revokes the access, which ends a download that runs
    /// under `CloudAccess.untilRevoked`.
    public func downloading<T: Sendable>(_ work: @Sendable (CloudAccess) async throws -> T) async throws -> T {
        // Subscribed before the grant, so a switch made in between is not missed.
        let changes = changes()
        let access = CloudAccess.granted(by: snapshot(), app: .unknown, keys: { _ in nil })
        // Iterated even when access was refused: cancelling the iteration is what
        // ends the subscription in the store.
        let watch = Task {
            for await preferences in changes where preferences.privacy != .standard {
                access?.revoke(.privateModeOn)
                return
            }
        }
        defer { watch.cancel() }
        guard let access else { throw CloudAccessRevoked(.privateModeOn) }
        return try await work(access)
    }
}
