/// Thrown by work that `CloudAccess.untilRevoked` cut short.
public struct CloudAccessRevoked: Error, Sendable, Hashable {
    public let reason: AccessRevoked
    public init(_ reason: AccessRevoked) { self.reason = reason }
}

private enum Finished<T: Sendable>: Sendable {
    case work(T)
    case watcherCancelled
}

extension CloudAccess {
    /// Runs `work` until it finishes or this access is revoked. A revoke cancels
    /// `work` and throws `CloudAccessRevoked` once `work` returns: a download
    /// stops mid-file (#5), local work that ignores cancellation (a CoreML
    /// compile) runs out first. Already revoked: `work` never starts.
    public func untilRevoked<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        if let revoked { throw CloudAccessRevoked(revoked) }
        return try await withThrowingTaskGroup(of: Finished<T>.self) { group in
            group.addTask { .work(try await work()) }
            group.addTask {
                if let reason = await self.whenRevoked() { throw CloudAccessRevoked(reason) }
                return .watcherCancelled
            }
            defer { group.cancelAll() }
            // The watcher ends without a revoke only once cancelled, so `work` decides.
            while let finished = try await group.next() {
                if case .work(let value) = finished { return value }
            }
            throw CancellationError()
        }
    }
}
