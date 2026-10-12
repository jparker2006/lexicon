import LexiconDomain

// Private mode and the always-private apps, checked for the life of the work
// that holds cloud access (#5).

extension Conductor {
    /// Revokes `access` the moment the settings or, `followingFocus`, the frontmost
    /// app deny it (`Preferences.cloudDenied`). Cancel the task when the work that
    /// holds `access` ends. Not following focus, `app` stays the Dictation's own app.
    func revokeWhenDenied(_ access: CloudAccess, in app: AppContext, followingFocus: Bool) -> Task<Void, Never> {
        let store = preferences
        let destination = destination
        // Now, before the caller's first use: the grant read the fn-down snapshot,
        // and Private mode may have been turned on since.
        if let reason = store.snapshot().cloudDenied(for: .app(app)) { access.revoke(reason) }
        return Task {
            // Subscribed before the first check, so no change falls between the two.
            let settingsChanges = store.changes()
            let focusChanges = followingFocus ? await destination.appChanges() : nil
            let (changes, post) = AsyncStream<AccessChange>.makeStream()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await now in settingsChanges { post.yield(.settings(now)) } }
                if let focusChanges {
                    group.addTask { for await now in focusChanges { post.yield(.focus(now)) } }
                }
                defer { group.cancelAll() }
                // Again once subscribed: a switch between the check above and here counts too.
                var settings = store.snapshot()
                var app = app
                if let reason = settings.cloudDenied(for: .app(app)) { return access.revoke(reason) }
                for await change in changes {
                    switch change {
                    case .settings(let now): settings = now
                    case .focus(let now): app = now
                    }
                    if let reason = settings.cloudDenied(for: .app(app)) { return access.revoke(reason) }
                }
            }
        }
    }
}

/// What `revokeWhenDenied` re-checks the privacy rule on.
private enum AccessChange: Sendable {
    case settings(Preferences)
    case focus(AppContext)
}
